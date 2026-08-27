//! Exercises the real load / call / reload / unload path against the example
//! guest library built by `build.zig`. The guest's installed path is injected
//! as `build_options.guest_lib_path`.

const std = @import("std");
const rl = @import("rl");
const build_options = @import("build_options");

const Api = struct {
    pub const state_size = fn () callconv(.c) usize;
    pub const state_align = fn () callconv(.c) usize;
    pub const init = fn (*anyopaque) callconv(.c) bool;
    pub const iterate = fn (*anyopaque) callconv(.c) bool;
    pub const deinit = fn (*anyopaque) callconv(.c) void;
    pub const reloaded = fn (*anyopaque) callconv(.c) void;
};

test "load, call, reload, call again against the example guest" {
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = try rl.Reloader(Api).init(gpa, io, .{ .source_path = build_options.guest_lib_path });
    defer r.deinit();

    try r.load();

    const size = r.get().state_size();
    try std.testing.expect(size > 0);

    var state = try rl.State.alloc(gpa, size, r.get().state_align());
    defer state.free(gpa);

    try std.testing.expect(r.get().init(state.ptr));
    try std.testing.expect(r.get().iterate(state.ptr));

    // No source change, but this still copies to the other slot, opens a
    // fresh handle, and unloads the old one.
    var reload_seen = false;
    try r.reload(.{ .userdata = &reload_seen, .after_load = struct {
        fn cb(_: *const rl.Reloader(Api).Module, ud: ?*anyopaque) void {
            const seen: *bool = @ptrCast(@alignCast(ud.?));
            seen.* = true;
        }
    }.cb });
    try std.testing.expect(reload_seen);

    try std.testing.expect(r.get().iterate(state.ptr));
    r.get().reloaded(state.ptr);
    r.get().deinit(state.ptr);
}

test "missing symbol is reported as an error" {
    const BadApi = struct {
        pub const definitely_not_exported = fn () callconv(.c) void;
    };
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();

    var r = try rl.Reloader(BadApi).init(gpa, threaded.io(), .{ .source_path = build_options.guest_lib_path });
    defer r.deinit();
    try std.testing.expectError(error.SymbolNotFound, r.load());
}
