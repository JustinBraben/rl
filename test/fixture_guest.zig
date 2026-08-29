//! A deliberately silent guest used only by `test/integration.zig`. Kept
//! separate from `example/guest.zig` (which logs on purpose) so a passing
//! `zig build test` produces no child stderr — see the plan / README notes on
//! why any test-child stderr makes the build runner print a misleading
//! "failed command:" line.

const std = @import("std");
const rl = @import("rl");

// This file is the root of the fixture library, so `std_options` is honored.
pub const std_options: std.Options = .{ .log_level = .err };

pub const State = struct { tick: u64 };

pub fn init(s: *State) !void {
    s.* = .{ .tick = 0 };
}

pub fn iterate(s: *State) !bool {
    s.tick += 1;
    return true;
}

pub fn deinit(s: *State) void {
    _ = s;
}

pub fn reloaded(s: *State) void {
    _ = s;
}

/// Deliberately faults, for the crash-handling tests.
pub export fn rl_fixture_boom(_: *anyopaque) callconv(.c) void {
    const p: *allowzero volatile u8 = @ptrFromInt(0);
    p.* = 1;
}

comptime {
    rl.guest.exportGameApi(@This(), .{});
}
