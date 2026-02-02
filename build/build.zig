const builtin = @import("builtin");
const std = @import("std");
const CrossTarget = std.Target.Query;

// Usage:
//   zig build -Dtarget=<target> -Doptimize=<optimization level>
// Supported targets:
//   x86-windows-gnu
//   x86-windows-msvc
//   x86_64-windows-gnu
//   x86_64-windows-msvc
//   aarch64-windows-gnu
//   aarch64-windows-msvc

const required_version = std.SemanticVersion.parse("0.15.0") catch unreachable;
const compatible = builtin.zig_version.order(required_version) != .lt;

pub fn build(b: *std.Build) void {
    if (!compatible) {
        std.log.err("Unsupported Zig compiler version", .{});
        return;
    }

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
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("../shim.manifest"),
    });

    exe.addCSourceFile(.{ .file = b.path("../shim.cpp"), .flags = &.{"-std=c++20"} });
    exe.linkSystemLibrary("shlwapi");
    exe.linkSystemLibrary("shell32");

    if (target.result.abi == .msvc) {
        exe.linkLibC();
    } else {
        exe.linkLibCpp();
        exe.subsystem = .Console;
        // NOTE: This requires a recent Zig version (0.12.0-dev.3493+3661133f9 or later)
        exe.mingw_unicode_entry_point = true;
    }

    b.installArtifact(exe);
}
