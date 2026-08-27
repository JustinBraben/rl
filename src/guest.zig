//! Optional guest-side helpers. None of this is required — a guest can just
//! write plain `export fn` entry points whose names match the host's `Api`
//! declarations. These helpers remove the repetitive
//! opaque-pointer-cast + error-catch + log boilerplate for the common
//! "game-shaped" guest.

const std = @import("std");

/// Logs a failed guest operation. Generic replacement for a hand-rolled
/// per-app error logger.
pub fn logError(
    comptime scope: @EnumLiteral(),
    comptime where: []const u8,
    err: anyerror,
) void {
    std.log.scoped(scope).err(where ++ " failed: {s}", .{@errorName(err)});
}

/// A `reloaded` entry point that does nothing, for guests that don't need to
/// react to a code swap.
pub fn noopReloaded(state: *anyopaque) callconv(.c) void {
    _ = state;
}

pub const GameApiOptions = struct {
    /// `std.log` scope used when a wrapped call returns an error.
    log_scope: @EnumLiteral() = .guest,
};

/// C-ABI wrappers for a game-shaped guest, matching the symbol names in this
/// package's example `Api` (`state_size`, `state_align`, `init`, `iterate`,
/// `deinit`, `event`, `reloaded`).
///
/// `Impl` must declare:
///   - `pub const State = struct { ... };`   — the host-owned state type
///   - `pub fn init(*State) anyerror!void`
///   - `pub fn iterate(*State) anyerror!bool` — return `false` to quit
///   - `pub fn deinit(*State) void`
/// and may declare:
///   - `pub const Event = SomeType;`         — pointee for `event` (default `anyopaque`)
///   - `pub fn event(*State, *Event) anyerror!bool`
///   - `pub fn reloaded(*State) void`
///
/// Usage:
/// ```zig
/// comptime rl.guest.exportGameApi(@This(), .{});
/// ```
pub fn GameApi(comptime Impl: type, comptime opts: GameApiOptions) type {
    const State = Impl.State;
    const Event = if (@hasDecl(Impl, "Event")) Impl.Event else anyopaque;
    const scope = opts.log_scope;

    return struct {
        pub fn state_size() callconv(.c) usize {
            return @sizeOf(State);
        }

        pub fn state_align() callconv(.c) usize {
            return @alignOf(State);
        }

        pub fn init(state: *anyopaque) callconv(.c) bool {
            const st: *State = @ptrCast(@alignCast(state));
            Impl.init(st) catch |err| {
                logError(scope, "init", err);
                return false;
            };
            return true;
        }

        pub fn iterate(state: *anyopaque) callconv(.c) bool {
            const st: *State = @ptrCast(@alignCast(state));
            return Impl.iterate(st) catch |err| {
                logError(scope, "iterate", err);
                return false;
            };
        }

        pub fn deinit(state: *anyopaque) callconv(.c) void {
            const st: *State = @ptrCast(@alignCast(state));
            Impl.deinit(st);
        }

        pub fn event(state: *anyopaque, ev: *anyopaque) callconv(.c) bool {
            if (!@hasDecl(Impl, "event")) return true;
            const st: *State = @ptrCast(@alignCast(state));
            const typed: *Event = @ptrCast(@alignCast(ev));
            return Impl.event(st, typed) catch |err| {
                logError(scope, "event", err);
                return false;
            };
        }

        pub fn reloaded(state: *anyopaque) callconv(.c) void {
            if (!@hasDecl(Impl, "reloaded")) return;
            const st: *State = @ptrCast(@alignCast(state));
            Impl.reloaded(st);
        }
    };
}

/// Generates `GameApi(Impl, opts)` and `@export`s every wrapper whose
/// corresponding `Impl` decl exists. Must be called in a `comptime` context.
pub fn exportGameApi(comptime Impl: type, comptime opts: GameApiOptions) void {
    const api = GameApi(Impl, opts);
    // Always present.
    @export(&api.state_size, .{ .name = "state_size" });
    @export(&api.state_align, .{ .name = "state_align" });
    @export(&api.init, .{ .name = "init" });
    @export(&api.iterate, .{ .name = "iterate" });
    @export(&api.deinit, .{ .name = "deinit" });
    // Optional; still exported (they degrade to no-ops) so a single host `Api`
    // works for every guest.
    @export(&api.event, .{ .name = "event" });
    @export(&api.reloaded, .{ .name = "reloaded" });
}

test "GameApi wraps a minimal Impl" {
    const Impl = struct {
        pub const State = struct { n: u32 };
        pub fn init(s: *State) !void {
            s.n = 1;
        }
        pub fn iterate(s: *State) !bool {
            s.n += 1;
            return s.n < 5;
        }
        pub fn deinit(s: *State) void {
            s.n = 0;
        }
    };
    const api = GameApi(Impl, .{});
    try std.testing.expectEqual(@sizeOf(Impl.State), api.state_size());
    try std.testing.expectEqual(@alignOf(Impl.State), api.state_align());

    var st: Impl.State = .{ .n = 99 };
    try std.testing.expect(api.init(&st));
    try std.testing.expectEqual(@as(u32, 1), st.n);
    try std.testing.expect(api.iterate(&st));
    try std.testing.expectEqual(@as(u32, 2), st.n);
    try std.testing.expect(api.event(&st, &st)); // no Impl.event -> pass-through true
    api.reloaded(&st); // no Impl.reloaded -> no-op
    api.deinit(&st);
    try std.testing.expectEqual(@as(u32, 0), st.n);
}
