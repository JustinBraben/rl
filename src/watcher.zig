//! Opt-in background file watcher.
//!
//! Polls a file's mtime on a dedicated thread and raises a one-shot "pending"
//! flag when it changes. The watcher never touches the guest module or its
//! state — the host calls `pending()` between frames and drives the reload
//! itself, so all load/unload work stays on the main thread.

const std = @import("std");

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    poll_interval_ms: u32,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    pending_flag: std.atomic.Value(bool),

    pub const Options = struct {
        /// Path to watch. Copied; the caller's slice need not outlive the call.
        path: []const u8,
        poll_interval_ms: u32 = 200,
    };

    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Watcher {
        const self = try gpa.create(Watcher);
        errdefer gpa.destroy(self);

        const path_copy = try gpa.dupe(u8, opts.path);
        errdefer gpa.free(path_copy);

        self.* = .{
            .gpa = gpa,
            .path = path_copy,
            .poll_interval_ms = opts.poll_interval_ms,
            .thread = undefined,
            .stop_flag = .init(false),
            .pending_flag = .init(false),
        };

        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the thread, joins it, and frees the watcher.
    pub fn stop(self: *Watcher) void {
        self.stop_flag.store(true, .release);
        self.thread.join();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    /// Returns `true` at most once per detected change (test-and-clear).
    pub fn pending(self: *Watcher) bool {
        return self.pending_flag.swap(false, .acquire);
    }

    fn run(self: *Watcher) void {
        // A private I/O instance for this thread, mirroring the pattern proven
        // in the breakout example this library was extracted from.
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var last_mtime: ?i96 = null;
        while (!self.stop_flag.load(.acquire)) {
            std.Io.sleep(io, .fromMilliseconds(self.poll_interval_ms), .awake) catch {};
            const st = std.Io.Dir.cwd().statFile(io, self.path, .{}) catch continue;
            const mtime = st.mtime.nanoseconds;
            if (last_mtime) |prev| {
                if (mtime != prev) self.pending_flag.store(true, .release);
            }
            last_mtime = mtime;
        }
    }
};

test "pending is a one-shot test-and-clear" {
    var w: Watcher = undefined;
    w.pending_flag = .init(false);
    try std.testing.expect(!w.pending());
    w.pending_flag.store(true, .release);
    try std.testing.expect(w.pending());
    try std.testing.expect(!w.pending());
}
