//! Host-side hot-reload machinery: load a guest shared library, swap its code
//! on demand, and keep the guest's state alive across swaps by having the host
//! own it.

const std = @import("std");
const builtin = @import("builtin");

const DynLib = @import("dynlib.zig").DynLib;

const log = std.log.scoped(.rl);

/// Platform affix for a shared library named `name`:
/// `libPrefix ++ name ++ libSuffix`.
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

/// Optional sugar for the host-owned state buffer. The guest exports its
/// `@sizeOf`/`@alignOf`; the host allocates once here, at a stable address,
/// and passes `ptr` into every guest call. The manual `allocator.rawAlloc`
/// path stays perfectly valid.
pub const State = struct {
    bytes: []u8,
    ptr: *anyopaque,
    alignment: std.mem.Alignment,

    pub fn alloc(gpa: std.mem.Allocator, size: usize, alignment: usize) error{OutOfMemory}!State {
        const a = std.mem.Alignment.fromByteUnits(alignment);
        const raw = gpa.rawAlloc(size, a, @returnAddress()) orelse return error.OutOfMemory;
        @memset(raw[0..size], 0);
        return .{ .bytes = raw[0..size], .ptr = @ptrCast(raw), .alignment = a };
    }

    pub fn free(self: State, gpa: std.mem.Allocator) void {
        gpa.rawFree(self.bytes, self.alignment, @returnAddress());
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
pub fn Reloader(comptime Api: type) type {
    return struct {
        const Self = @This();

        const symbol_prefix: []const u8 = if (@hasDecl(Api, "symbol_prefix")) Api.symbol_prefix else "";

        /// Typed view of the currently-loaded guest: one function pointer per
        /// `Api` declaration, plus the live library handle. Valid only until
        /// the next `reload`.
        pub const Module = ApiModule(Api);

        pub const Options = struct {
            /// Path to the freshly-built guest library. Copied.
            source_path: []const u8,
            /// Directory for the alternating side copies. Defaults to the
            /// directory containing `source_path`.
            temp_dir: ?[]const u8 = null,
            /// Explicit names for the two side-copy slots. Defaults to
            /// `<stem>.rl0<ext>` / `<stem>.rl1<ext>` next to `temp_dir`.
            slot_names: ?[2][]const u8 = null,
            copy_retries: u32 = 20,
            copy_retry_backoff_ms: u32 = 50,
        };

        pub const ReloadHooks = struct {
            userdata: ?*anyopaque = null,
            /// Called with the outgoing module just before it is unloaded.
            before_unload: ?*const fn (old: *const Module, userdata: ?*anyopaque) void = null,
            /// Called with the freshly-loaded module just after the swap.
            after_load: ?*const fn (new: *const Module, userdata: ?*anyopaque) void = null,
        };

        gpa: std.mem.Allocator,
        io: std.Io,
        source_path: []const u8,
        slots: [2][]const u8,
        copy_retries: u32,
        copy_retry_backoff_ms: u32,
        next_slot: usize,
        current: ?Module,

        pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !Self {
            const source_path = try gpa.dupe(u8, opts.source_path);
            errdefer gpa.free(source_path);

            var slots: [2][]const u8 = undefined;
            var made: usize = 0;
            errdefer for (slots[0..made]) |s| gpa.free(s);
            for (&slots, 0..) |*slot, i| {
                slot.* = if (opts.slot_names) |names|
                    try gpa.dupe(u8, names[i])
                else
                    try defaultSlotName(gpa, opts.source_path, opts.temp_dir, i);
                made += 1;
            }

            // Best-effort: clear side copies a crashed previous run may have
            // left behind, so this run can reuse slot 0. If one is still
            // locked by a live process this fails harmlessly and the later
            // copy/open will surface the real conflict.
            for (slots) |s| std.Io.Dir.cwd().deleteFile(io, s) catch {};

            return .{
                .gpa = gpa,
                .io = io,
                .source_path = source_path,
                .slots = slots,
                .copy_retries = opts.copy_retries,
                .copy_retry_backoff_ms = opts.copy_retry_backoff_ms,
                .next_slot = 0,
                .current = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.current) |*m| m.dynlib.close();
            self.current = null;
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
            self.current = try self.loadSlot(self.next_slot);
            self.next_slot = 1 - self.next_slot;
        }

        /// Copy the newest guest build into the free slot, load it, unload the
        /// previous one. On any failure the current module is left untouched
        /// and the error is returned.
        pub fn reload(self: *Self, hooks: ReloadHooks) !void {
            const slot = self.next_slot;
            var new_module = try self.loadSlot(slot);
            errdefer new_module.dynlib.close();

            if (self.current) |*old| {
                if (hooks.before_unload) |cb| cb(old, hooks.userdata);
                old.dynlib.close();
            }
            self.current = new_module;
            self.next_slot = 1 - slot;
            if (hooks.after_load) |cb| cb(&self.current.?, hooks.userdata);
        }

        /// Typed function pointers for the loaded guest. Asserts a module is
        /// loaded.
        pub fn get(self: *Self) *const Module {
            return &(self.current orelse unreachable);
        }

        fn loadSlot(self: *Self, slot: usize) !Module {
            try self.copyWithRetry(self.source_path, self.slots[slot]);
            var dl = try DynLib.open(self.slots[slot]);
            errdefer dl.close();
            return try bind(&dl);
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
            inline for (@typeInfo(Module).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, "dynlib")) continue;
                const sym = comptime std.fmt.comptimePrint("{s}{s}", .{ symbol_prefix, f.name });
                @field(m, f.name) = m.dynlib.lookup(f.type, sym) orelse {
                    // warn, not err: a failed reload keeps the previous
                    // version running, and a failed initial load returns
                    // this error to the caller to handle.
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

    comptime var count: usize = 1; // + "dynlib"
    inline for (api_decls) |d| {
        if (!std.mem.eql(u8, d.name, "symbol_prefix")) count += 1;
    }

    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.builtin.Type.StructField.Attributes = undefined;

    names[0] = "dynlib";
    types[0] = DynLib;
    attrs[0] = .{};

    var n: usize = 1;
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

test "Module has one field per Api decl plus the handle" {
    const M = Reloader(TestApi).Module;
    const fields = @typeInfo(M).@"struct".fields;
    try testing.expectEqual(@as(usize, 3), fields.len); // dynlib + state_size + step
    try testing.expect(@hasField(M, "dynlib"));
    try testing.expect(@hasField(M, "state_size"));
    try testing.expect(@hasField(M, "step"));
    try testing.expect(!@hasField(M, "symbol_prefix"));
    try testing.expectEqual(*const fn () callconv(.c) usize, @FieldType(M, "state_size"));
}

test "defaultSlotName derives sibling names, honouring temp_dir" {
    const a = try defaultSlotName(testing.allocator, "build" ++ std.fs.path.sep_str ++ "game.dll", null, 0);
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("build" ++ std.fs.path.sep_str ++ "game.rl0.dll", a);

    const b = try defaultSlotName(testing.allocator, "/pkg/bin/libgame.so", "/tmp/rl", 1);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/rl" ++ std.fs.path.sep_str ++ "libgame.rl1.so", b);
}

test "State.alloc gives a zeroed, aligned, freeable buffer" {
    const S = extern struct { a: u64, b: u32 };
    var st = try State.alloc(testing.allocator, @sizeOf(S), @alignOf(S));
    defer st.free(testing.allocator);
    try testing.expectEqual(@sizeOf(S), st.bytes.len);
    try testing.expect(st.alignment.check(@intFromPtr(st.ptr)));
    for (st.bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);
}
