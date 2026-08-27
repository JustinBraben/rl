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

    const it_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    it_mod.addImport("rl", mod);
    const it_opts = b.addOptions();
    it_opts.addOption(
        []const u8,
        "guest_lib_path",
        b.getInstallPath(.bin, HotReload.libFileName(b, target, "example_guest")),
    );
    it_mod.addOptions("build_options", it_opts);

    const it_tests = b.addTest(.{ .root_module = it_mod });
    const run_it_tests = b.addRunArtifact(it_tests);
    // The integration test loads the installed guest library.
    run_it_tests.step.dependOn(example.guest_install);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_it_tests.step);
}
