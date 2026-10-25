const std = @import("std");

const Opts = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    /// Keep debug info (PDB) in debug builds. Off by default: generating it roughly doubles dev build time.
    debug_info: bool,

    fn strip(o: Opts) bool {
        return o.optimize != .debug or !o.debug_info;
    }
};

/// Debug builds use Zig's self-hosted backend (no LLVM): much faster edit loop. Release keeps LLVM.
fn tune(o: Opts, exe: *std.Build.Step.Compile) *std.Build.Step.Compile {
    if (o.optimize == .debug and exe.rootModuleTarget().cpu.arch == .wasm32) exe.use_llvm = false;
    return exe;
}

fn engineModule(o: Opts) *std.Build.Module {
    return o.b.createModule(.{
        .root_source_file = o.b.path("src/engine.zig"),
        .target = o.target,
        .optimize = o.optimize,
    });
}

fn addCli(o: Opts) *std.Build.Step.Compile {
    return tune(o, o.b.addExecutable(.{
        .name = "frame2d",
        .root_module = o.b.createModule(.{
            .root_source_file = o.b.path("src/cli.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .strip = o.strip(),
            .single_threaded = true,
            .imports = &.{.{ .name = "engine", .module = engineModule(o) }},
        }),
    }));
}

fn addServer(o: Opts) *std.Build.Step.Compile {
    const b = o.b;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .strip = o.strip(),
        .imports = &.{.{ .name = "engine", .module = engineModule(o) }},
    });
    const sqlite = b.dependency("sqlite", .{});
    mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_OMIT_DEPRECATED=1" },
    });
    return tune(o, b.addExecutable(.{ .name = "frame2d-server", .root_module = mod }));
}

const ClientSteps = struct { check: *std.Build.Step };

fn clientRoot(o: Opts, target: std.Build.ResolvedTarget, dvui_mod: *std.Build.Module, web_mod: ?*std.Build.Module) *std.Build.Module {
    const b = o.b;
    const eng = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = o.optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = o.optimize,
        .strip = o.strip(),
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
            .{ .name = "engine", .module = eng },
        },
    });
    if (web_mod) |w| mod.addImport("web-backend", w);
    return mod;
}

fn addClients(o: Opts) ClientSteps {
    const b = o.b;
    const check = b.step("check-clients", "Compile desktop and web clients without emitting binaries");

    // desktop (SDL3)
    const dd = b.dependency("dvui", .{ .target = o.target, .optimize = o.optimize, .backend = .sdl3 });
    const dmod = clientRoot(o, o.target, dd.module("dvui_sdl3"), null);
    const desk = tune(o, b.addExecutable(.{ .name = "frame2d-app", .root_module = dmod }));
    const desk_install = b.addInstallArtifact(desk, .{});
    b.step("desktop", "Build the desktop app").dependOn(&desk_install.step);
    b.getInstallStep().dependOn(&desk_install.step);
    const desk_check = b.addExecutable(.{ .name = "frame2d-app", .root_module = clientRoot(o, o.target, dd.module("dvui_sdl3"), null) });
    check.dependOn(&desk_check.step);

    // web (wasm32-freestanding, dvui web backend)
    const wasm = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wd = b.dependency("dvui", .{ .target = wasm, .optimize = o.optimize, .backend = .web });
    const web_exe = addWebExe(o, wasm, wd);
    const web_check = addWebExe(o, wasm, wd);
    check.dependOn(&web_check.step);
    const web_step = b.step("web", "Build the static web directory (zig-out/web)");
    web_step.dependOn(&b.addInstallFileWithDir(web_exe.getEmittedBin(), .{ .custom = "web" }, "web.wasm").step);
    web_step.dependOn(&b.addInstallFileWithDir(wd.namedLazyPath("web.js"), .{ .custom = "web" }, "web.js").step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("web/index.html"), .{ .custom = "web" }, "index.html").step);
    b.getInstallStep().dependOn(web_step);
    return .{ .check = check };
}

fn addWebExe(o: Opts, wasm: std.Build.ResolvedTarget, wd: *std.Build.Dependency) *std.Build.Step.Compile {
    const mod = clientRoot(o, wasm, wd.module("dvui_web"), wd.module("web"));
    mod.single_threaded = true;
    const exe = tune(o, o.b.addExecutable(.{ .name = "web", .root_module = mod }));
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const debug_info = b.option(bool, "debug-info", "keep debug info in debug builds (slower dev builds)") orelse false;
    const o = Opts{ .b = b, .target = target, .optimize = optimize, .debug_info = debug_info };

    const cli_install = b.addInstallArtifact(addCli(o), .{});
    const server_install = b.addInstallArtifact(addServer(o), .{});
    b.step("cli", "Build the frame2d CLI").dependOn(&cli_install.step);
    b.step("server", "Build the frame2d server").dependOn(&server_install.step);
    b.getInstallStep().dependOn(&cli_install.step);
    b.getInstallStep().dependOn(&server_install.step);

    const dvui_step = addClients(o);

    // `zig build check`: compile everything without emitting binaries.
    const check = b.step("check", "Compile all targets without emitting binaries");
    check.dependOn(&addCli(o).step);
    check.dependOn(&addServer(o).step);
    check.dependOn(dvui_step.check);

    const tests = b.addTest(.{ .root_module = engineModule(o) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
