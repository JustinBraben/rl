//! The thin, never-reloaded half of the example. Loads `guest.zig` as a
//! shared library, owns the state, and drives the loop.

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

    var reloader = try rl.Reloader(ExampleApi).init(gpa, io, .{ .source_path = guest_path });
    defer reloader.deinit();
    try reloader.load();

    var state = try rl.State.alloc(gpa, reloader.get().state_size(), reloader.get().state_align());
    defer state.free(gpa);

    if (!reloader.get().init(state.ptr)) return error.GuestInitFailed;
    defer reloader.get().deinit(state.ptr);

    var watcher = try rl.Watcher.start(gpa, .{ .path = guest_path });
    defer watcher.stop();

    std.log.info("running — edit example/guest.zig and `zig build`; Ctrl+C to quit", .{});

    while (true) {
        if (!reloader.get().iterate(state.ptr)) break;

        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

        if (watcher.pending()) {
            reloader.reload(.{}) catch |err| {
                std.log.warn("reload failed, keeping previous version: {s}", .{@errorName(err)});
                continue;
            };
            reloader.get().reloaded(state.ptr);
        }
    }
}
