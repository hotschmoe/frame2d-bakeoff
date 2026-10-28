const std = @import("std");
const teak = @import("teak");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip release binaries (default: true unless Debug)") orelse (optimize != .debug);

    const check = b.step("check", "Compile everything without installing (zig build check)");

    // ── CLI ──
    const cli = b.addExecutable(.{
        .name = "frame2d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const cli_step = b.step("cli", "Build the frame2d CLI");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    check.dependOn(&cli.step);

    // ── server (std.http + SQLite) ──
    const sqlite_dep = b.dependency("sqlite", .{});
    const sqlite_tc = b.addTranslateC(.{
        .root_source_file = sqlite_dep.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite_c", .module = sqlite_tc.createModule() }},
    });
    server_mod.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0" },
    });
    // SQLite is compiled with optimizations even in Debug so the dev loop stays fast at runtime.
    const server = b.addExecutable(.{ .name = "frame2d-server", .root_module = server_mod });
    const server_step = b.step("server", "Build the frame2d server");
    server_step.dependOn(&b.addInstallArtifact(server, .{}).step);
    check.dependOn(&server.step);

    // ── desktop app (Teak, Win32/X11 + wgpu-native) ──
    if (teak.hasNativeBackend(target.result.os.tag)) {
        const app = b.addExecutable(.{
            .name = "frame2d-app",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
            }),
        });
        teak.linkNativeWgpu(b, app, .{});
        const desktop_step = b.step("desktop", "Build the desktop app");
        desktop_step.dependOn(&b.addInstallArtifact(app, .{}).step);
        check.dependOn(&app.step);
    }

    // ── web (wasm32-freestanding + zunk/WebGPU) ──
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });
        const wasm_opt: std.builtin.OptimizeMode = if (optimize == .debug) .safe else optimize;
        const web_teak = b.dependency("teak", .{ .target = wasm_target, .optimize = wasm_opt });
        const app_mod = b.createModule(.{
            .root_source_file = b.path("src/ui.zig"),
            .target = wasm_target,
            .optimize = wasm_opt,
            .imports = &.{.{ .name = "teak", .module = web_teak.module("teak") }},
        });
        const web = b.addExecutable(.{
            .name = "web",
            .root_module = b.createModule(.{
                .root_source_file = b.path("web/main.zig"),
                .target = wasm_target,
                .optimize = wasm_opt,
                .imports = &.{.{ .name = "frame2d_app", .module = app_mod }},
            }),
        });
        teak.linkWebWgpu(b, web, .{ .output_dir = "dist" });
    }

    // ── tests (engine + UI state, no window) ──
    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "teak", .module = teak_dep.module("teak") }},
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
