//! `rl` — a small, reusable hot-reload library for Zig, in the spirit of
//! `cr.h`. A thin host process loads a guest shared library, swaps its code
//! on demand, and keeps the guest's state alive across swaps because the host
//! owns it.
//!
//! v1 scope: cross-platform code reload (Windows / Linux / macOS), typed
//! symbol access, host-owned state. No crash protection / rollback, no
//! automatic `.state`/`.bss` section transfer — see the README.

const reload = @import("reload.zig");

/// Host: build a reloader for a guest described by an `Api` struct type.
pub const Reloader = reload.Reloader;
/// Host: optional sugar for the host-owned state buffer.
pub const State = reload.State;
/// Platform shared-library affixes and name helper.
pub const lib_prefix = reload.lib_prefix;
pub const lib_suffix = reload.lib_suffix;
pub const libName = reload.libName;

/// Host: opt-in background mtime watcher.
pub const Watcher = @import("watcher.zig").Watcher;

/// Host: cross-platform dynamic library loader (used internally by
/// `Reloader`; exposed for advanced use).
pub const DynLib = @import("dynlib.zig").DynLib;

/// Guest-side helpers (optional).
pub const guest = @import("guest.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = reload;
    _ = @import("watcher.zig");
    _ = @import("dynlib.zig");
    _ = guest;
}
