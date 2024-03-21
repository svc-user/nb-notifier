const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tray_mod = b.addModule("tray", .{ .source_file = .{ .cwd_relative = "vendor/zig-tray/src/tray.zig" } });
    const exe = b.addExecutable(.{
        .name = "nb-notifier",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("tray", tray_mod);

    b.installArtifact(exe);
    b.installFile("icon.ico", "bin/icon.ico");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const check = b.step("check", "check build");
    check.dependOn(&exe.step);
}
