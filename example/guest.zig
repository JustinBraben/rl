//! The hot-reloadable half of the example. Build the whole thing with
//! `zig build`, run it with `zig build run`, then edit the marked line below
//! and `zig build` again in another terminal — the running process picks up
//! the change without losing `tick`.

const std = @import("std");
const rl = @import("rl");

/// Owned by the host, at a stable address, for the life of the process.
/// Only this library's *code* is swapped on reload; changing the shape of
/// this struct needs a full restart.
pub const State = struct {
    tick: u64,
};

pub fn init(state: *State) !void {
    state.* = .{ .tick = 0 };
    std.log.scoped(.guest).info("init", .{});
}

pub fn iterate(state: *State) !bool {
    state.tick += 1;

    // ↓↓↓ EDIT THIS LINE while `zig build run` is going ↓↓↓
    std.log.scoped(.guest).info("tick {d}: hello from the guest", .{state.tick});
    // ↑↑↑ then run `zig build` — the message changes live ↑↑↑

    return true; // return false to ask the host to quit; Ctrl+C also works
}

pub fn deinit(state: *State) void {
    std.log.scoped(.guest).info("deinit after {d} ticks", .{state.tick});
}

pub fn reloaded(state: *State) void {
    std.log.scoped(.guest).info("code reloaded at tick {d} (state kept)", .{state.tick});
}

comptime {
    rl.guest.exportGameApi(@This(), .{ .log_scope = .guest });
}
