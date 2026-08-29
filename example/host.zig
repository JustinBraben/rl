//! The thin, never-reloaded half of the example. Loads `guest.zig` as a
//! shared library, owns the state, drives the loop, and — because it opts
//! into `crash_handling` — catches a guest fault and rolls the guest code
//! back to the previous build instead of dying.

const std = @import("std");
const rl = @import("rl");

/// The guest's exported symbols. Names must match what the guest exports
/// (here, via `rl.guest.exportGameApi`).
pub const ExampleApi = struct {
    pub const state_size = fn () callconv(.c) usize;
    pub const state_align = fn () callconv(.c) usize;
    pub const init = fn (*anyopaque) callconv(.c) bool;
    pub const iterate = fn (*anyopaque) callconv(.c) bool;
    pub const deinit = fn (*anyopaque) callconv(.c) void;
    pub const reloaded = fn (*anyopaque) callconv(.c) void;
};

const Host = rl.Reloader(ExampleApi, .{ .crash_handling = true });

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(exe_dir);

    const guest_path = try std.fs.path.join(gpa, &.{ exe_dir, rl.libName("example_guest") });
    defer gpa.free(guest_path);

    var reloader = try Host.init(gpa, io, .{ .source_path = guest_path });
    defer reloader.deinit();
    try reloader.load();

    var state = try rl.State.alloc(gpa, reloader.get().state_size(), reloader.get().state_align());
    defer state.free(gpa);
    try state.enableBackup(gpa);

    if (!try reloader.call("init", .{state.ptr})) return error.GuestInitFailed;
    defer _ = reloader.call("deinit", .{state.ptr}) catch {};
    state.commit();

    var watcher = try rl.Watcher.start(gpa, .{ .path = guest_path });
    defer watcher.stop();

    std.log.info("running — edit example/guest.zig and `zig build`; Ctrl+C to quit", .{});

    while (true) {
        const keep = reloader.call("iterate", .{state.ptr}) catch |err| switch (err) {
            error.GuestCrashed => {
                std.log.warn("guest crashed ({s}); rolling back", .{@tagName(reloader.last_crash)});
                state.restore();
                reloader.rollback() catch |e| {
                    std.log.err("cannot roll back ({s}); giving up", .{@errorName(e)});
                    return error.GuestCrashed; // first-version crash is fatal (matches cr.h)
                };
                _ = reloader.call("reloaded", .{state.ptr}) catch {};
                continue;
            },
        };
        if (!keep) break;
        state.commit();

        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

        if (watcher.pending()) {
            reloader.reload(.{}) catch |err| {
                std.log.warn("reload failed, keeping previous version: {s}", .{@errorName(err)});
                continue;
            };
            _ = reloader.call("reloaded", .{state.ptr}) catch {};
        }
    }
}
