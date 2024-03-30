const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

// Usage:
//   zig build -Dtarget=<target> -Doptimize=<optimization level>
// Supported targets:
//   x86_64-windows-gnu
//   x86_64-windows-msvc
//   aarch64-windows-gnu
//   aarch64-windows-msvc

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{ .default_target = CrossTarget{
        .os_tag = .windows,
        .abi = .gnu,
    } });

    if (target.result.os.tag != .windows) {
        std.log.err("Non-Windows target is not supported", .{});
        return;
    }

    const exe = b.addExecutable(.{
        .name = "shim",
        .target = target,
        .optimize = optimize,
        .win32_manifest = .{ .path = "shim.manifest" },
    });

    exe.addCSourceFile(.{ .file = .{ .path = "shim.cpp" }, .flags = &.{"-std=c++20"} });
    exe.linkSystemLibrary("shlwapi");

    if (target.result.abi == .msvc) {
        exe.linkLibC();
    } else {
        exe.linkLibCpp();
        exe.subsystem = .Windows;
        // NOTE: This requires a recent Zig version (0.12.0-dev.3493+3661133f9 or later)
        exe.mingw_unicode_entry_point = true;
    }

    b.installArtifact(exe);
}
