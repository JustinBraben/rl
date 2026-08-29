//! Host-side hot-reload machinery: load a guest shared library, swap its code
//! on demand, keep the guest's state alive across swaps (the host owns it),
//! and — optionally — catch a guest crash and roll its code back to the
//! previously-loaded version.

const std = @import("std");
const builtin = @import("builtin");

const DynLib = @import("dynlib.zig").DynLib;
pub const guard = @import("guard.zig");

const log = std.log.scoped(.rl);

/// Platform affix for a shared library named `name`:
/// `lib_prefix ++ name ++ lib_suffix`.
pub const lib_prefix = switch (builtin.target.os.tag) {
    .windows => "",
    else => "lib",
};
pub const lib_suffix = switch (builtin.target.os.tag) {
    .windows => ".dll",
    .macos => ".dylib",
    else => ".so",
};

/// Convenience for the guest library's on-disk name, e.g. `"game.dll"` /
/// `"libgame.so"`. Comptime so it can be used with `std.fs.path.join`.
pub fn libName(comptime name: []const u8) []const u8 {
    return lib_prefix ++ name ++ lib_suffix;
}

/// Reloader behaviour knobs, fixed at comptime.
pub const Config = struct {
    /// Route guest calls made through `Reloader.call` via a fault guard, and
    /// enable `Reloader.rollback`. Requires `guard.supported` for the target.
    crash_handling: bool = false,
    /// How many previous code versions to keep loaded for rollback. Only
    /// meaningful with `crash_handling`; clamped to at least 1 there.
    rollback_depth: usize = 1,
};

/// Why the reloader is in a failed state. See `Reloader.failure`.
pub const Failure = enum {
    none,
    /// A guarded guest call faulted; call `rollback`.
    crash,
    /// A crash with no previous version to roll back to. Fatal (matches cr.h).
    initial_failure,
    /// Ran out of history rolling back repeated crashes.
    rollback_exhausted,
};

/// The kind of fault from the last caught crash.
pub const CrashCode = guard.Code;

/// Optional sugar for the host-owned state buffer. The guest exports its
/// `@sizeOf`/`@alignOf`; the host allocates once here, at a stable address,
/// and passes `ptr` into every guest call.
pub const State = struct {
    bytes: []u8,
    ptr: *anyopaque,
    alignment: std.mem.Alignment,
    /// Known-good checkpoint, allocated by `enableBackup`.
    backup: ?[]u8 = null,

    pub fn alloc(gpa: std.mem.Allocator, size: usize, alignment: usize) error{OutOfMemory}!State {
        const a = std.mem.Alignment.fromByteUnits(alignment);
        const raw = gpa.rawAlloc(size, a, @returnAddress()) orelse return error.OutOfMemory;
        @memset(raw[0..size], 0);
        return .{ .bytes = raw[0..size], .ptr = @ptrCast(raw), .alignment = a };
    }

    pub fn free(self: State, gpa: std.mem.Allocator) void {
        if (self.backup) |b| gpa.free(b);
        gpa.rawFree(self.bytes, self.alignment, @returnAddress());
    }

    /// Allocate the checkpoint buffer and seed it with the current state.
    pub fn enableBackup(self: *State, gpa: std.mem.Allocator) error{OutOfMemory}!void {
        std.debug.assert(self.backup == null);
        const b = try gpa.alloc(u8, self.bytes.len);
        @memcpy(b, self.bytes);
        self.backup = b;
    }

    /// Save the current state as the checkpoint (call after a good frame).
    pub fn commit(self: State) void {
        @memcpy(self.backup.?, self.bytes);
    }

    /// Restore the state from the checkpoint (call on the rollback path).
    pub fn restore(self: State) void {
        @memcpy(self.bytes, self.backup.?);
    }
};

/// Build a reloader for a guest whose exported symbols are described by `Api`.
///
/// `Api` is a struct type whose public declarations name the expected symbols
/// and give each a function type:
///
/// ```zig
/// const GameApi = struct {
///     pub const state_size = fn () callconv(.c) usize;
///     pub const state_align = fn () callconv(.c) usize;
///     pub const init = fn (*anyopaque) callconv(.c) bool;
///     pub const iterate = fn (*anyopaque) callconv(.c) bool;
///     pub const reloaded = fn (*anyopaque) callconv(.c) void;
///     // optional: pub const symbol_prefix = "game_";
/// };
/// ```
pub fn Reloader(comptime Api: type, comptime cfg: Config) type {
    if (cfg.crash_handling and !guard.supported) {
        @compileError("rl: crash_handling is not implemented for " ++ @tagName(builtin.target.os.tag) ++
            " (Emscripten/web in particular is unsupported)");
    }

    return struct {
        const Self = @This();

        const symbol_prefix: []const u8 = if (@hasDecl(Api, "symbol_prefix")) Api.symbol_prefix else "";
        const eff_depth: usize = if (cfg.crash_handling) @max(1, cfg.rollback_depth) else 0;
        const slot_count: usize = eff_depth + 2;

        /// Typed view of the currently-loaded guest: one function pointer per
        /// `Api` declaration, plus the live library handle and its slot.
        /// Valid only until the next `reload`/`rollback`.
        pub const Module = ApiModule(Api);

        pub const Options = struct {
            /// Path to the freshly-built guest library. Copied.
            source_path: []const u8,
            /// Directory for the side copies. Defaults to the directory
            /// containing `source_path`.
            temp_dir: ?[]const u8 = null,
            copy_retries: u32 = 20,
            copy_retry_backoff_ms: u32 = 50,
            /// Size of the POSIX signal alternate stack (crash handling only).
            alt_stack_size: usize = 32 * 1024,
        };

        pub const ReloadHooks = struct {
            userdata: ?*anyopaque = null,
            /// Called when a module stops being `current` (it may still be
            /// kept loaded for rollback).
            before_unload: ?*const fn (old: *const Module, userdata: ?*anyopaque) void = null,
            /// Called with the freshly-loaded module just after the swap.
            after_load: ?*const fn (new: *const Module, userdata: ?*anyopaque) void = null,
        };

        pub const CallError = error{GuestCrashed};
        pub const RollbackError = error{RollbackExhausted};

        gpa: std.mem.Allocator,
        io: std.Io,
        source_path: []const u8,
        slots: [slot_count][]const u8,
        copy_retries: u32,
        copy_retry_backoff_ms: u32,
        current: ?Module,

        history: [eff_depth]Module,
        history_len: usize,
        version: u32,
        failure: Failure,
        last_crash: CrashCode,
        alt_stack: []u8,

        pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Self {
            const source_path = try gpa.dupe(u8, opts.source_path);
            errdefer gpa.free(source_path);

            var slots: [slot_count][]const u8 = undefined;
            var made: usize = 0;
            errdefer for (slots[0..made]) |s| gpa.free(s);
            for (&slots, 0..) |*slot, i| {
                slot.* = try defaultSlotName(gpa, opts.source_path, opts.temp_dir, i);
                made += 1;
            }

            const alt_stack: []u8 = if (cfg.crash_handling)
                try gpa.alloc(u8, opts.alt_stack_size)
            else
                &.{};
            errdefer if (cfg.crash_handling) gpa.free(alt_stack);

            // Best-effort: clear side copies a crashed previous run may have
            // left behind.
            for (slots) |s| std.Io.Dir.cwd().deleteFile(io, s) catch {};

            if (cfg.crash_handling) guard.install(alt_stack);

            return .{
                .gpa = gpa,
                .io = io,
                .source_path = source_path,
                .slots = slots,
                .copy_retries = opts.copy_retries,
                .copy_retry_backoff_ms = opts.copy_retry_backoff_ms,
                .current = null,
                .history = undefined,
                .history_len = 0,
                .version = 0,
                .failure = .none,
                .last_crash = .none,
                .alt_stack = alt_stack,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.current) |*m| m.dynlib.close();
            self.current = null;
            for (self.history[0..self.history_len]) |*m| m.dynlib.close();
            self.history_len = 0;

            if (cfg.crash_handling) {
                guard.uninstall();
                self.gpa.free(self.alt_stack);
            }
            for (self.slots) |s| {
                std.Io.Dir.cwd().deleteFile(self.io, s) catch {};
                self.gpa.free(s);
            }
            self.gpa.free(self.source_path);
            self.* = undefined;
        }

        /// First load. Asserts nothing is loaded yet.
        pub fn load(self: *Self) !void {
            std.debug.assert(self.current == null);
            self.current = try self.loadSlot(self.freeSlot());
            self.version = 1;
        }

        /// Copy the newest guest build into a free slot and load it. The
        /// outgoing module is either unloaded (no crash handling) or kept for
        /// rollback. On any failure the current module is left untouched.
        pub fn reload(self: *Self, hooks: ReloadHooks) !void {
            var nm = try self.loadSlot(self.freeSlot());
            errdefer nm.dynlib.close();

            if (self.current) |*oldp| {
                if (hooks.before_unload) |cb| cb(oldp, hooks.userdata);
            }

            if (comptime eff_depth == 0) {
                if (self.current) |*old| old.dynlib.close();
            } else if (self.current) |old| {
                if (self.history_len == eff_depth) {
                    self.history[0].dynlib.close();
                    var i: usize = 1;
                    while (i < self.history_len) : (i += 1) self.history[i - 1] = self.history[i];
                    self.history_len -= 1;
                }
                self.history[self.history_len] = old;
                self.history_len += 1;
            }

            self.current = nm;
            self.version += 1;
            if (hooks.after_load) |cb| cb(&self.current.?, hooks.userdata);
        }

        /// Typed function pointers for the loaded guest. Asserts a module is
        /// loaded and no crash is pending.
        pub fn get(self: *Self) *const Module {
            std.debug.assert(self.failure == .none);
            return &(self.current orelse unreachable);
        }

        /// Invoke guest export `name` with `args`. When `cfg.crash_handling`
        /// this is fault-guarded: a caught crash sets `failure`/`last_crash`
        /// and returns `error.GuestCrashed` (call `rollback` next). Otherwise
        /// it is a direct call and never returns the error.
        pub fn call(
            self: *Self,
            comptime name: []const u8,
            args: anytype,
        ) CallError!CallRet(name) {
            const f = @field(self.current.?, name);
            if (comptime !cfg.crash_handling) {
                return @call(.auto, f, args);
            }
            return guard.call(@TypeOf(f), f, args) catch |e| switch (e) {
                error.GuestCrashed => {
                    self.failure = .crash;
                    self.last_crash = guard.lastCode();
                    return error.GuestCrashed;
                },
            };
        }

        fn CallRet(comptime name: []const u8) type {
            const FnPtr = @FieldType(Module, name);
            return @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
        }

        /// After a caught crash, discard the broken module and make the
        /// previously-loaded version current again. Returns
        /// `error.RollbackExhausted` (and sets `failure` to `.initial_failure`
        /// or `.rollback_exhausted`) when there is no version to fall back to.
        pub fn rollback(self: *Self) RollbackError!void {
            std.debug.assert(self.failure != .none);
            if (self.history_len == 0) {
                self.failure = if (self.version <= 1) .initial_failure else .rollback_exhausted;
                return error.RollbackExhausted;
            }
            self.current.?.dynlib.close();
            self.history_len -= 1;
            self.current = self.history[self.history_len];
            self.failure = .none;
            self.last_crash = .none;
            self.version -= 1;
        }

        fn freeSlot(self: *Self) usize {
            var used = [_]bool{false} ** slot_count;
            if (self.current) |m| used[m.slot] = true;
            for (self.history[0..self.history_len]) |m| used[m.slot] = true;
            for (used, 0..) |u, i| if (!u) return i;
            unreachable; // slot_count = eff_depth + 2 guarantees a free slot
        }

        fn loadSlot(self: *Self, slot: usize) !Module {
            try self.copyWithRetry(self.source_path, self.slots[slot]);
            var dl = try DynLib.open(self.slots[slot]);
            errdefer dl.close();
            var m = try bind(&dl);
            m.slot = slot;
            return m;
        }

        fn copyWithRetry(self: *Self, src: []const u8, dst: []const u8) !void {
            const cwd = std.Io.Dir.cwd();
            var attempt: u32 = 0;
            while (true) {
                if (cwd.copyFile(src, cwd, dst, self.io, .{})) |_| {
                    return;
                } else |err| {
                    attempt += 1;
                    if (attempt >= self.copy_retries) return err;
                    std.Io.sleep(self.io, .fromMilliseconds(self.copy_retry_backoff_ms), .awake) catch {};
                }
            }
        }

        fn bind(dl: *DynLib) !Module {
            var m: Module = undefined;
            m.dynlib = dl.*;
            m.slot = 0;
            inline for (@typeInfo(Module).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "dynlib")) continue;
                if (comptime std.mem.eql(u8, field.name, "slot")) continue;
                const sym = comptime std.fmt.comptimePrint("{s}{s}", .{ symbol_prefix, field.name });
                @field(m, field.name) = m.dynlib.lookup(field.type, sym) orelse {
                    log.warn("guest symbol not found: '{s}'", .{sym});
                    return error.SymbolNotFound;
                };
            }
            return m;
        }
    };
}

fn ApiModule(comptime Api: type) type {
    const api_decls = @typeInfo(Api).@"struct".decls;

    comptime var count: usize = 2; // "dynlib" + "slot"
    inline for (api_decls) |d| {
        if (!std.mem.eql(u8, d.name, "symbol_prefix")) count += 1;
    }

    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;

    names[0] = "dynlib";
    types[0] = DynLib;
    attrs[0] = .{};
    names[1] = "slot";
    types[1] = usize;
    attrs[1] = .{};

    var n: usize = 2;
    inline for (api_decls) |d| {
        if (std.mem.eql(u8, d.name, "symbol_prefix")) continue;
        names[n] = d.name;
        types[n] = *const @field(Api, d.name);
        attrs[n] = .{};
        n += 1;
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

fn defaultSlotName(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    temp_dir: ?[]const u8,
    slot: usize,
) ![]const u8 {
    const dir = temp_dir orelse (std.fs.path.dirname(source_path) orelse ".");
    const base = std.fs.path.basename(source_path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    const fname = try std.fmt.allocPrint(gpa, "{s}.rl{d}{s}", .{ stem, slot, ext });
    defer gpa.free(fname);
    return std.fs.path.join(gpa, &.{ dir, fname });
}

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

const TestApi = struct {
    pub const symbol_prefix = "t_";
    pub const state_size = fn () callconv(.c) usize;
    pub const step = fn (*anyopaque) callconv(.c) bool;
};

test "Module has one field per Api decl plus the handle and slot" {
    const M = Reloader(TestApi, .{}).Module;
    const fields = @typeInfo(M).@"struct".fields;
    try testing.expectEqual(@as(usize, 4), fields.len); // dynlib + slot + state_size + step
    try testing.expect(@hasField(M, "dynlib"));
    try testing.expect(@hasField(M, "slot"));
    try testing.expect(@hasField(M, "state_size"));
    try testing.expect(@hasField(M, "step"));
    try testing.expect(!@hasField(M, "symbol_prefix"));
    try testing.expectEqual(*const fn () callconv(.c) usize, @FieldType(M, "state_size"));
}

test "slot_count tracks crash-handling config" {
    try testing.expectEqual(@as(usize, 2), Reloader(TestApi, .{}).slot_count);
    try testing.expectEqual(@as(usize, 3), Reloader(TestApi, .{ .crash_handling = true }).slot_count);
    try testing.expectEqual(
        @as(usize, 4),
        Reloader(TestApi, .{ .crash_handling = true, .rollback_depth = 2 }).slot_count,
    );
}

test "defaultSlotName derives sibling names, honouring temp_dir" {
    const a = try defaultSlotName(testing.allocator, "build" ++ std.fs.path.sep_str ++ "game.dll", null, 0);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("build" ++ std.fs.path.sep_str ++ "game.rl0.dll", a);

    const b = try defaultSlotName(testing.allocator, "/pkg/bin/libgame.so", "/tmp/rl", 1);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/rl" ++ std.fs.path.sep_str ++ "libgame.rl1.so", b);
}

test "State.alloc + enableBackup + commit/restore" {
    const S = extern struct { a: u64, b: u32 };
    var st = try State.alloc(testing.allocator, @sizeOf(S), @alignOf(S));
    defer st.free(testing.allocator);
    try testing.expectEqual(@sizeOf(S), st.bytes.len);
    try testing.expect(st.alignment.check(@intFromPtr(st.ptr)));

    try st.enableBackup(testing.allocator);
    st.bytes[0] = 0xAB;
    st.commit();
    st.bytes[0] = 0xCD;
    st.restore();
    try testing.expectEqual(@as(u8, 0xAB), st.bytes[0]);
}
