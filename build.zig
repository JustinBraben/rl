const std = @import("std");

/// `build.zig` helper for consumers: `rl.HotReload.add(b, .{ ... })`.
pub const HotReload = @import("build/HotReload.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable library module.
    const mod = b.addModule("rl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // --- example: host exe + hot-reloadable guest lib, via the helper ---
    const example = HotReload.add(b, .{
        .name = "example_guest",
        .host_name = "example_host",
        .host_root = b.path("example/host.zig"),
        .guest_root = b.path("example/guest.zig"),
        .target = target,
        .optimize = optimize,
        .rl_module = mod,
    });

    const run_example = b.addRunArtifact(example.host);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);

    const run_step = b.step("run", "Build and run the hot-reload example");
    run_step.dependOn(&run_example.step);
    b.step("example", "Build the hot-reload example").dependOn(b.getInstallStep());

    // --- tests ---
    const link_libc = switch (target.result.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A silent guest library, built just for the integration test so a green
    // `zig build test` emits no child stderr (see test/fixture_guest.zig).
    const fixture_guest_mod = b.createModule(.{
        .root_source_file = b.path("test/fixture_guest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    fixture_guest_mod.addImport("rl", mod);
    const fixture_guest = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "rl_fixture_guest",
        .root_module = fixture_guest_mod,
    });

    const it_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    it_mod.addImport("rl", mod);
    const it_opts = b.addOptions();
    // A LazyPath, so the test step waits for the fixture lib and gets its
    // absolute path with no install-step coupling.
    it_opts.addOptionPath("guest_lib_path", fixture_guest.getEmittedBin());
    it_mod.addOptions("build_options", it_opts);

    const it_tests = b.addTest(.{ .root_module = it_mod });
    const run_it_tests = b.addRunArtifact(it_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_it_tests.step);
}
