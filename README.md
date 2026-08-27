# rl

A small, reusable **hot-reload** library for Zig, in the spirit of
[`cr.h`](https://github.com/fungos/cr).

A thin **host** process loads your app as a **guest** shared library, swaps the
guest's *code* whenever you rebuild it, and keeps the guest's *state* alive
across swaps because the host owns it. Edit, `zig build`, watch your running
program change — no restart.

Tested on Windows; the Linux/macOS paths are implemented but need a run on
those platforms to be called proven.

## Features

- [X] Cross-platform code reload (Windows `LoadLibraryW`, Linux/macOS `dlopen`)
- [X] Typed, checked access to the guest's exported symbols
- [X] Host-owned state that survives reloads
- [X] `build.zig` helper, opt-in file watcher, guest-side helpers, example
- [ ] No crash protection / rollback — a bad guest crashes the process
- [ ] No automatic `.state` / `.bss` section transfer (host owns the state instead)
- [ ] No hot-reload of the host itself

## Install

```sh
zig fetch --save git+https://github.com/JustinBraben/rl
```

```zig
// build.zig
const rl = @import("rl"); // this package's build helper
const rl_dep = b.dependency("rl", .{ .target = target, .optimize = optimize });

const hr = rl.HotReload.add(b, .{
    .name = "game",                     // -> game.dll / libgame.so
    .host_root = b.path("src/host.zig"),
    .guest_root = b.path("src/game.zig"),
    .target = target,
    .optimize = optimize,
    .rl_module = rl_dep.module("rl"),
});

const run = b.addRunArtifact(hr.host);
run.step.dependOn(b.getInstallStep());
b.step("run", "Run").dependOn(&run.step);
```

The helper builds the host executable and the guest dynamic library with
matching settings and installs both into `bin` side-by-side. On Linux/macOS it
sets `link_libc` on both so `std.DynLib` resolves to the real `dlopen`
(`DlDynLib`), not the no-libc `ElfDynLib`.

## Use

### Guest (`src/game.zig`)

Describe your state and lifecycle as plain functions, then export them. The
`rl.guest` helper wraps the opaque-pointer casts and error logging:

```zig
const std = @import("std");
const rl = @import("rl");

pub const State = struct { score: u32, /* ... */ };

pub fn init(s: *State) !void { s.* = .{ .score = 0 }; }
pub fn iterate(s: *State) !bool { s.score += 1; return true; } // false -> quit
pub fn deinit(s: *State) void { _ = s; }
pub fn reloaded(s: *State) void { _ = s; } // optional: re-cache host pointers here

comptime { rl.guest.exportGameApi(@This(), .{}); }
```

Or skip the helper entirely and write plain `export fn init(...) callconv(.c) bool { ... }`
whose names match the host's `Api`.

### Host (`src/host.zig`)

```zig
const std = @import("std");
const rl = @import("rl");

// Names + signatures of the symbols the guest exports.
const Api = struct {
    pub const state_size = fn () callconv(.c) usize;
    pub const state_align = fn () callconv(.c) usize;
    pub const init = fn (*anyopaque) callconv(.c) bool;
    pub const iterate = fn (*anyopaque) callconv(.c) bool;
    pub const deinit = fn (*anyopaque) callconv(.c) void;
    pub const reloaded = fn (*anyopaque) callconv(.c) void;
    // optional: pub const symbol_prefix = "game_";
};

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const exe_dir = try std.process.executableDirPathAlloc(io, gpa);
    defer gpa.free(exe_dir);
    const guest_path = try std.fs.path.join(gpa, &.{ exe_dir, rl.libName("game") });
    defer gpa.free(guest_path);

    var reloader = try rl.Reloader(Api).init(gpa, io, .{ .source_path = guest_path });
    defer reloader.deinit();
    try reloader.load();

    var state = try rl.State.alloc(gpa, reloader.get().state_size(), reloader.get().state_align());
    defer state.free(gpa);
    if (!reloader.get().init(state.ptr)) return error.GuestInitFailed;
    defer reloader.get().deinit(state.ptr);

    var watcher = try rl.Watcher.start(gpa, .{ .path = guest_path });
    defer watcher.stop();

    while (true) {
        if (!reloader.get().iterate(state.ptr)) break;
        std.Io.sleep(io, .fromMilliseconds(16), .awake) catch {};

        if (watcher.pending()) {
            reloader.reload(.{}) catch |err| {
                std.log.warn("reload failed, keeping previous version: {s}", .{@errorName(err)});
                continue;
            };
            reloader.get().reloaded(state.ptr);
        }
    }
}
```

## API

| Symbol | Purpose |
| --- | --- |
| `rl.Reloader(Api)` | Generic reloader. `Api` is a struct type whose pub decls name the guest's symbols and give each a fn type. `.Module` is the generated typed view. |
| `Reloader(Api).init/deinit/load/reload/get` | `load` first-loads; `reload(hooks)` copies the newest build into the free slot, opens it, unloads the old one — on failure the current module is untouched and the error is returned. `get()` returns the typed fn pointers (valid until the next `reload`). |
| `Reloader(Api).ReloadHooks` | Optional `before_unload` / `after_load` callbacks + `userdata`, run inside `reload()`. |
| `rl.State` | Sugar: `alloc(gpa, size, align)` a zeroed, stably-addressed buffer for the guest's state; `free(gpa)`. |
| `rl.Watcher` | Opt-in background mtime poller. `start(gpa, .{ .path, .poll_interval_ms })`, `pending()` (one-shot test-and-clear), `stop()`. |
| `rl.libName("game")` | `"game.dll"` / `"libgame.so"` / `"libgame.dylib"` (comptime). |
| `rl.guest.exportGameApi(@This(), .{})` | Generates + `@export`s C-ABI wrappers for a game-shaped guest. |
| `rl.guest.logError` / `noopReloaded` | Standalone guest helpers. |
| `rl.DynLib` | The cross-platform loader used internally; exposed for advanced use. |

## How the swap stays safe

`reload()` never touches the file `zig build` writes. It copies that file to
one of two alternating side names (`game.rl0.dll` / `game.rl1.dll`) and loads
*that*, so the build output is never locked (Windows) or served from a stale
mapping (Linux/macOS), and the slot being overwritten is never the one
currently loaded. `deinit` deletes the side copies; `init` also clears stale
ones from a crashed prior run.

## Constraints

- **State layout is fixed at runtime.** Only the guest's code is swapped.
  Adding, removing, or reordering `State` fields needs a full restart.
- **Don't cache guest function pointers across a reload** except through
  `reloader.get()`. Same caveat as `cr`.
- **Shared dependencies must be one instance.** If host and guest both use,
  say, SDL, link it dynamically into both (`shared_libraries` on the helper)
  so they share one runtime and one event queue — never two static copies.

## SDL / translate-c apps

Pass the modules and libraries both sides share:

```zig
const hr = rl.HotReload.add(b, .{
    // ...
    .shared_imports = &.{ .{ .name = "c", .module = translate_c_mod } },
    .shared_libraries = &.{ sdl_dep.artifact("SDL3") }, // built with .preferred_linkage = .dynamic
});
b.installArtifact(sdl_dep.artifact("SDL3"));
```

Web / Emscripten is out of the helper's scope: there is no runtime reload
there, so link the "guest" statically into the host and skip `rl` on that
target.

## Develop

```sh
zig build test    # unit tests + an integration test that loads the example guest
zig build run     # the example: prints a tick; edit example/guest.zig and `zig build`
```

## License

MIT — see [LICENSE](LICENSE).
