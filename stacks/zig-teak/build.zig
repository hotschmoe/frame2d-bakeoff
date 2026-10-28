const std = @import("std");
const teak = @import("teak");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip release binaries (default: true unless Debug)") orelse (optimize != .debug);
    // Debug CLI + desktop use Zig's self-hosted x86_64 backend (no LLVM): build_dev ~3 s instead of ~8 s.
    // Costs: Debug code is slower and Windows panics have no symbols (no PDB); -Dself-hosted=false for LLVM.
    // The server stays on LLVM: the self-hosted Debug server segfaults at startup (SQLite + libc).
    // Release builds always use LLVM.
    const self_hosted = b.option(bool, "self-hosted", "Debug: self-hosted backend instead of LLVM") orelse true;
    const use_llvm: ?bool = if (optimize == .debug and self_hosted and target.result.cpu.arch == .x86_64) false else null;

    // `check` = semantic analysis of every target with -fno-emit-bin (no codegen, no link): each target
    // gets a second, never-installed Compile sharing its root module, which is what tells the build
    // system to skip the binary.
    const check = b.step("check", "Type-check everything, no codegen (zig build check)");

    // ── CLI ──
    const cli = b.addExecutable(.{
        .name = "frame2d",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const cli_step = b.step("cli", "Build the frame2d CLI");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);
    _ = addCheck(b, check, cli);

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
    // sqlite3.c follows the build mode (-O0 in Debug: cheapest cold dev build; the object is cached).
    const server = b.addExecutable(.{ .name = "frame2d-server", .root_module = server_mod });
    const server_step = b.step("server", "Build the frame2d server");
    server_step.dependOn(&b.addInstallArtifact(server, .{}).step);
    _ = addCheck(b, check, server);

    // ── desktop app (Teak, Win32/X11 + wgpu-native) ──
    if (teak.hasNativeBackend(target.result.os.tag)) {
        const app = b.addExecutable(.{
            .name = "frame2d-app",
            .use_llvm = use_llvm,
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
        _ = addCheck(b, check, app);
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
        teak.linkWebWgpu(b, web, .{ .output_dir = "dist", .bridge_js = b.path("web/bridge.js") });
        const web_check = addCheck(b, check, web);
        web_check.entry = .disabled;
        web_check.rdynamic = true;
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

fn addCheck(b: *std.Build, check: *std.Build.Step, exe: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const c = b.addExecutable(.{ .name = b.fmt("{s}-check", .{exe.name}), .root_module = exe.root_module });
    check.dependOn(&c.step);
    return c;
}
