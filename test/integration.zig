//! Exercises the real load / call / reload / rollback path against a silent
//! fixture guest library built by `build.zig`. Its path is injected as
//! `build_options.guest_lib_path`.

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
    pub const rl_fixture_boom = fn (*anyopaque) callconv(.c) void;
};

/// Absolute path of a private directory for this test's side copies, so they
/// never collide with `zig-out/bin` or a concurrently running `zig build run`.
fn tmpPath(tmp: *std.testing.TmpDir, io: std.Io, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

fn allocState(gpa: std.mem.Allocator, m: anytype) !rl.State {
    return rl.State.alloc(gpa, m.state_size(), m.state_align());
}

test "load, call, reload, call again against the fixture guest" {
    std.testing.log_level = .err;

    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = try tmpPath(&tmp, io, &pbuf);

    var r = try rl.Reloader(Api, .{}).init(gpa, io, .{
        .source_path = build_options.guest_lib_path,
        .temp_dir = temp_dir,
    });
    defer r.deinit();

    try r.load();

    const size = r.get().state_size();
    try std.testing.expect(size > 0);

    var state = try allocState(gpa, r.get().*);
    defer state.free(gpa);

    try std.testing.expect(r.get().init(state.ptr));
    try std.testing.expect(r.get().iterate(state.ptr));

    var reload_seen = false;
    try r.reload(.{ .userdata = &reload_seen, .after_load = struct {
        fn cb(_: *const rl.Reloader(Api, .{}).Module, ud: ?*anyopaque) void {
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
    std.testing.log_level = .err;

    const BadApi = struct {
        pub const definitely_not_exported = fn () callconv(.c) void;
    };
    const gpa = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = try tmpPath(&tmp, io, &pbuf);

    var r = try rl.Reloader(BadApi, .{}).init(gpa, io, .{
        .source_path = build_options.guest_lib_path,
        .temp_dir = temp_dir,
    });
    defer r.deinit();
    try std.testing.expectError(error.SymbolNotFound, r.load());
}

test "crash handling: catch a fault and roll back to the previous version" {
    if (!rl.guard.supported) return error.SkipZigTest;
    std.testing.log_level = .err;

    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = try tmpPath(&tmp, io, &pbuf);

    const R = rl.Reloader(Api, .{ .crash_handling = true });
    var r = try R.init(gpa, io, .{
        .source_path = build_options.guest_lib_path,
        .temp_dir = temp_dir,
    });
    defer r.deinit();

    try r.load();
    // A second load so there is a known-good version in history.
    try r.reload(.{});
    try std.testing.expectEqual(@as(u32, 2), r.version);

    var state = try allocState(gpa, r.get().*);
    defer state.free(gpa);
    try state.enableBackup(gpa);
    try std.testing.expect(try r.call("init", .{state.ptr}));
    state.commit();

    // Fault.
    try std.testing.expectError(error.GuestCrashed, r.call("rl_fixture_boom", .{state.ptr}));
    try std.testing.expectEqual(rl.Failure.crash, r.failure);
    try std.testing.expectEqual(rl.CrashCode.segfault, r.last_crash);

    // Recover.
    state.restore();
    try r.rollback();
    try std.testing.expectEqual(rl.Failure.none, r.failure);
    try std.testing.expectEqual(@as(u32, 1), r.version);
    try std.testing.expect(try r.call("iterate", .{state.ptr}));
}

test "crash handling: first-version crash is unrecoverable" {
    if (!rl.guard.supported) return error.SkipZigTest;
    std.testing.log_level = .err;

    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = try tmpPath(&tmp, io, &pbuf);

    const R = rl.Reloader(Api, .{ .crash_handling = true });
    var r = try R.init(gpa, io, .{
        .source_path = build_options.guest_lib_path,
        .temp_dir = temp_dir,
    });
    defer r.deinit();

    try r.load();
    var state = try allocState(gpa, r.get().*);
    defer state.free(gpa);

    try std.testing.expectError(error.GuestCrashed, r.call("rl_fixture_boom", .{state.ptr}));
    try std.testing.expectError(error.RollbackExhausted, r.rollback());
    try std.testing.expectEqual(rl.Failure.initial_failure, r.failure);
}
