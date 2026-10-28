const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release artifacts carry no debug info (smaller binaries; the dev loop keeps full Debug info).
    const strip = optimize != .debug;

    const engine = b.addModule("engine", .{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
            .strip = strip,
    });

    const cli = b.addExecutable(.{
        .name = "frame2d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    b.installArtifact(cli);

    const sqlite = b.dependency("sqlite", .{});
    const server = b.addExecutable(.{
        .name = "frame2d-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .imports = &.{.{ .name = "engine", .module = engine }},
        }),
    });
    server.root_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_SHARED_CACHE", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_DECLTYPE", "-fno-sanitize=undefined" },
    });
    b.installArtifact(server);

    // Desktop engine library for dart:ffi. Flutter on win-arm64 is an x64 app, so the target is selectable.
    const lib_target = if (b.option([]const u8, "desktop-target", "Target triple of the desktop engine library (default: native)")) |t|
        b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = t }) catch @panic("bad -Ddesktop-target"))
    else
        target;
    const bridge_lib = b.addLibrary(.{
        .name = "frame2d_engine",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge/exports.zig"),
            .target = lib_target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "engine", .module = b.createModule(.{
                .root_source_file = b.path("src/engine/engine.zig"),
                .target = lib_target,
                .optimize = optimize,
            .strip = strip,
            }) }},
        }),
    });
    b.installArtifact(bridge_lib);

    // The same exports as WebAssembly for Flutter web (loaded through dart:js_interop).
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const wasm = b.addExecutable(.{
        .name = "frame2d_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge/exports.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "engine", .module = b.createModule(.{
                .root_source_file = b.path("src/engine/engine.zig"),
                .target = wasm_target,
                .optimize = optimize,
            .strip = strip,
            }) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "web" }, "frame2d_engine.wasm").step);

    // Engine library + WASM for the Dart bridge tests (test_all), in their own dir so the release
    // artifacts in zig-out/bin and zig-out/web are never replaced by these builds.
    const bridge_test = b.step("bridge-test-libs", "Install the engine library and WASM into zig-out/test-bridge");
    bridge_test.dependOn(&b.addInstallArtifact(bridge_lib, .{
        .dest_dir = .{ .override = .{ .custom = "test-bridge" } },
        .implib_dir = .disabled,
        .pdb_dir = .disabled,
    }).step);
    bridge_test.dependOn(&b.addInstallFileWithDir(wasm.getEmittedBin(), .{ .custom = "test-bridge" }, "frame2d_engine.wasm").step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
            .strip = strip,
    }) });
    const test_step = b.step("test", "Run engine unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const check = b.step("check", "Compile everything without installing");
    check.dependOn(&cli.step);
    check.dependOn(&server.step);
    check.dependOn(&bridge_lib.step);
    check.dependOn(&wasm.step);
    check.dependOn(&tests.step);
}
