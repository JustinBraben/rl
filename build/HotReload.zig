//! `build.zig` helper: wire up a hot-reload host executable + guest dynamic
//! library with matching settings, installed side-by-side in `bin`.
//!
//! From a consumer `build.zig`:
//! ```zig
//! const rl = @import("rl"); // this package
//! const rl_dep = b.dependency("rl", .{ .target = target, .optimize = optimize });
//! const hr = rl.HotReload.add(b, .{
//!     .name = "game",
//!     .host_root = b.path("src/host.zig"),
//!     .guest_root = b.path("src/game.zig"),
//!     .target = target,
//!     .optimize = optimize,
//!     .rl_module = rl_dep.module("rl"),
//! });
//! const run = b.addRunArtifact(hr.host);
//! run.step.dependOn(b.getInstallStep());
//! b.step("run", "Run").dependOn(&run.step);
//! ```

const std = @import("std");

pub const Import = struct {
    name: []const u8,
    module: *std.Build.Module,
};

pub const AddOptions = struct {
    /// Base name of the guest library: `game` -> `game.dll` / `libgame.so`.
    name: []const u8,
    /// Name for the host executable. Defaults to `name`.
    host_name: ?[]const u8 = null,
    host_root: std.Build.LazyPath,
    guest_root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The `rl` module, e.g. `b.dependency("rl", .{...}).module("rl")`.
    rl_module: *std.Build.Module,
    /// Modules imported by BOTH host and guest under the same name (e.g. a
    /// translate-c `"c"` module shared by an SDL app).
    shared_imports: []const Import = &.{},
    /// Libraries linked into BOTH host and guest. Use dynamic linkage so the
    /// two sides resolve against a single running instance (see README).
    shared_libraries: []const *std.Build.Step.Compile = &.{},
    /// Extra options applied to the host module only.
    host_link_libc: ?bool = null,
    /// Extra options applied to the guest module only.
    guest_link_libc: ?bool = null,
    /// The host uses `rl`'s crash guard (`Reloader(Api, .{ .crash_handling = true })`).
    /// Forces `link_libc` on the host so the POSIX `sigsetjmp`/`siglongjmp`
    /// symbols resolve; harmless on Windows.
    crash_handling: bool = false,
};

pub const Result = struct {
    host: *std.Build.Step.Compile,
    guest: *std.Build.Step.Compile,
    /// Install step for the guest library. Depend on this from a run step.
    guest_install: *std.Build.Step,
    host_install: *std.Build.Step,
};

/// On Linux/macOS the host must `link_libc` so `std.DynLib` resolves to the
/// real `dlopen` (`DlDynLib`) rather than the no-libc `ElfDynLib`, which does
/// not process the guest's own dynamic relocations.
fn defaultLinkLibc(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

pub fn add(b: *std.Build, opts: AddOptions) Result {
    const libc_default = defaultLinkLibc(opts.target);

    // ---- guest: dynamic library ----
    const guest_mod = b.createModule(.{
        .root_source_file = opts.guest_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = opts.guest_link_libc orelse libc_default,
    });
    guest_mod.addImport("rl", opts.rl_module);
    for (opts.shared_imports) |imp| guest_mod.addImport(imp.name, imp.module);
    for (opts.shared_libraries) |lib| guest_mod.linkLibrary(lib);

    const guest = b.addLibrary(.{
        .linkage = .dynamic,
        .name = opts.name,
        .root_module = guest_mod,
    });

    // Install as a plain sibling of the exe on every OS (Windows already does
    // this for DLLs; force the same for .so/.dylib).
    const guest_install = b.addInstallArtifact(guest, .{
        .dest_dir = .{ .override = .bin },
    });
    b.getInstallStep().dependOn(&guest_install.step);

    // ---- host: executable ----
    const host_mod = b.createModule(.{
        .root_source_file = opts.host_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = opts.host_link_libc orelse (libc_default or opts.crash_handling),
    });
    host_mod.addImport("rl", opts.rl_module);
    for (opts.shared_imports) |imp| host_mod.addImport(imp.name, imp.module);
    for (opts.shared_libraries) |lib| host_mod.linkLibrary(lib);

    const host = b.addExecutable(.{
        .name = opts.host_name orelse opts.name,
        .root_module = host_mod,
    });
    const host_install = b.addInstallArtifact(host, .{});
    host_install.step.dependOn(&guest_install.step);
    b.getInstallStep().dependOn(&host_install.step);

    return .{
        .host = host,
        .guest = guest,
        .guest_install = &guest_install.step,
        .host_install = &host_install.step,
    };
}

/// On-disk file name of a shared library for `target`, e.g. `game.dll` /
/// `libgame.so`. Useful for pointing a `Reloader` at the installed guest.
pub fn libFileName(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8) []const u8 {
    const os = target.result.os.tag;
    const prefix = if (os == .windows) "" else "lib";
    const suffix: []const u8 = switch (os) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
    return b.fmt("{s}{s}{s}", .{ prefix, name, suffix });
}
