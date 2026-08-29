# rl

A small, reusable **hot-reload** library for Zig, in the spirit of
[`cr.h`](https://github.com/fungos/cr).

A thin **host** process loads your app as a **guest** shared library, swaps the
guest's *code* whenever you rebuild it, and keeps the guest's *state* alive
across swaps because the host owns it. Edit, `zig build`, watch your running
program change — no restart.

Tested on Windows (reload, watcher, and crash-catch / rollback all exercised).
The Linux/macOS paths are implemented but not yet run on those platforms.

## Features

- [X] Cross-platform code reload (Windows `LoadLibraryW`, Linux/macOS `dlopen`)
- [X] Typed, checked access to the guest's exported symbols
- [X] Host-owned state that survives reloads
- [X] `build.zig` helper, opt-in file watcher, guest-side helpers, example
- [X] **Opt-in crash protection & rollback** — catch a guest fault, roll its
  code back to the last good version, keep running
  ([details](#crash-handling--rollback)); not implemented for Emscripten/web
- [ ] Automatic `.state` / `.bss` section transfer (host owns the state instead)
- [ ] Hot-reload of the host itself

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
(`DlDynLib`), not the no-libc `ElfDynLib`. Pass `.crash_handling = true` if the
host uses `Reloader(Api, .{ .crash_handling = true })` (see
[Crash handling & rollback](#crash-handling--rollback)).

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

    // `.{}` = no crash handling; see "Crash handling & rollback" below.
    var reloader = try rl.Reloader(Api, .{}).init(gpa, io, .{ .source_path = guest_path });
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
| `rl.Reloader(Api, Config)` | Generic reloader. `Api` is a struct type whose pub decls name the guest's symbols and give each a fn type. `Config{ .crash_handling = false, .rollback_depth = 1 }`. `.Module` is the generated typed view. |
| `Reloader(...).init/deinit/load/reload/get` | `load` first-loads; `reload(hooks)` copies the newest build into a free slot and opens it (the old module is unloaded, or kept for rollback when `crash_handling`). `get()` returns the typed fn pointers (valid until the next `reload`/`rollback`). |
| `Reloader(...).call(name, args)` | Invoke guest export `name`. With `crash_handling` it is fault-guarded: a caught crash returns `error.GuestCrashed` and sets `.failure`/`.last_crash`. Without it, a plain direct call. |
| `Reloader(...).rollback()` | After a caught crash, discard the broken module and make the previous version current. `error.RollbackExhausted` when there is nothing to fall back to. |
| `Reloader(...).failure` / `.last_crash` / `.version` | `rl.Failure` (`none`/`crash`/`initial_failure`/`rollback_exhausted`), `rl.CrashCode` (`segfault`/`illegal`/…), load counter. |
| `Reloader(...).ReloadHooks` | Optional `before_unload` / `after_load` callbacks + `userdata`, run inside `reload()`. |
| `rl.State` | Sugar: `alloc(gpa, size, align)` a zeroed, stably-addressed buffer; `free(gpa)`. `enableBackup(gpa)` + `commit()` / `restore()` for crash-rollback checkpoints. |
| `rl.Watcher` | Opt-in background mtime poller. `start(gpa, .{ .path, .poll_interval_ms })`, `pending()` (one-shot test-and-clear), `stop()`. |
| `rl.guard.supported` | Comptime bool: whether crash handling is implemented for the target. |
| `rl.libName("game")` | `"game.dll"` / `"libgame.so"` / `"libgame.dylib"` (comptime). |
| `rl.guest.exportGameApi(@This(), .{})` | Generates + `@export`s C-ABI wrappers for a game-shaped guest. |
| `rl.guest.logError` / `noopReloaded` | Standalone guest helpers. |
| `rl.DynLib` | The cross-platform loader used internally; exposed for advanced use. |

## How the swap stays safe

`reload()` never touches the file `zig build` writes. It copies that file to a
rotating side name (`game.rl0.dll`, `game.rl1.dll`, …) and loads *that*, so the
build output is never locked (Windows) or served from a stale mapping
(Linux/macOS), and the slot being overwritten is never one that is currently
loaded. Two slots without crash handling; `rollback_depth + 2` with it (the
extra slots hold the previous versions kept for rollback). `deinit` deletes the
side copies; `init` also clears stale ones from a crashed prior run.

## Crash handling & rollback

Opt in per reloader:

```zig
const Host = rl.Reloader(Api, .{ .crash_handling = true }); // rollback_depth defaults to 1
```

Then call guest functions through `reloader.call(...)` instead of
`reloader.get().*(...)`, keep a state checkpoint, and handle
`error.GuestCrashed`:

```zig
var state = try rl.State.alloc(gpa, m.state_size(), m.state_align());
try state.enableBackup(gpa);
if (!try reloader.call("init", .{state.ptr})) return error.GuestInitFailed;
state.commit();

while (true) {
    const keep = reloader.call("iterate", .{state.ptr}) catch |err| switch (err) {
        error.GuestCrashed => {
            std.log.warn("guest crashed ({s}); rolling back", .{@tagName(reloader.last_crash)});
            state.restore();
            reloader.rollback() catch return error.GuestCrashed; // nothing to roll back to
            _ = reloader.call("reloaded", .{state.ptr}) catch {};
            continue;
        },
    };
    if (!keep) break;
    state.commit();
    // ... reload on watcher.pending() as usual, via reloader.call ...
}
```

How it works:

- **POSIX**: `sigaction` for SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT plus libc
  `sigsetjmp`/`siglongjmp`. The host must `link_libc` (the build helper's
  `.crash_handling = true` does this).
- **Windows**: a Vectored Exception Handler rewrites the faulting thread's
  `CONTEXT` back to a point captured with `RtlCaptureContext` before the call.
- Non-guest crashes still reach Zig's own segfault handler (POSIX chains to
  the previously-installed action; the Windows VEH returns
  `EXCEPTION_CONTINUE_SEARCH` when no guarded call is active).

Limits (same spirit as `cr.h`):

- **One guarded call at a time, from one thread.** There is a single global
  jump target.
- **First-version crash is fatal.** If the very first loaded guest crashes
  there is nothing to roll back to: `failure` becomes `.initial_failure`,
  `rollback()` returns `error.RollbackExhausted`.
- **State may be inconsistent** if the guest faulted mid-write — hence the
  opt-in `State` checkpoint. A guest that crashes while holding an OS resource
  (mutex, handle) still leaks it.
- **Windows stack-overflow recovery is best-effort** (the guard page is not
  restored).
- **Not implemented for Emscripten/web** — `crash_handling = true` on that
  target is a `@compileError`.

Supported targets: Windows, Linux, macOS (any arch). Elsewhere
`rl.guard.supported` is `false`.

## Constraints

- **State layout is fixed at runtime.** Only the guest's code is swapped.
  Adding, removing, or reordering `State` fields needs a full restart.
- **Don't cache guest function pointers across a reload/rollback** — re-fetch
  via `reloader.get()` / `reloader.call()` each frame. Same caveat as `cr`.
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
zig build test    # unit + integration tests (incl. crash-catch / rollback)
zig build run     # the example: prints a tick; edit example/guest.zig and `zig build`
```

The example host opts into `crash_handling`. Set `crash_at` in
`example/guest.zig` to a tick number and `zig build` while it runs: the
reloaded code faults there, the host catches it, rolls back to the previous
build, and keeps going. Set it back to `null` and `zig build` to recover.

## License

MIT — see [LICENSE](LICENSE).
