//! Frame2D client (dvui): root file for the desktop (SDL3) and web (wasm) builds.
const std = @import("std");
const dvui = @import("dvui");
const engine = @import("engine");
const solver = engine.solver;
const model_mod = engine.model;
const platform = @import("platform.zig");
const state = @import("state.zig");
const canvas = @import("canvas.zig");
const table = @import("table.zig");
const bench = @import("bench.zig");

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &startOptions },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn startOptions() dvui.App.StartOptions {
    platform.markEntry();
    platform.parseArgs();
    return .{
        .size = .{ .w = 1280, .h = 800 },
        .min_size = .{ .w = 640, .h = 400 },
        .vsync = platform.bench_mode == .none,
        .org = "frame2d",
        .app = "frame2d",
        .title = "Frame2D",
        .persist_window_geometry = false,
    };
}

var app: state.App = undefined;

fn appInit(_: *dvui.Window) !void {
    solver.clock_ns = platform.nowNs;
    app = state.App.init(std.heap.page_allocator);
    if (platform.bench_mode == .none) app.generate(2, 2);
}

fn appDeinit(_: *dvui.Window) void {}

// ---- wasm entry points used by index.html (benchmarks and boundary measurement)

fn setBench(mode: i32) callconv(.c) void {
    platform.bench_mode = platform.modeFromIndex(mode);
}

fn noopExport() callconv(.c) void {}

var echo_buf: [38103]f64 = undefined;
fn echoExport(n: usize) callconv(.c) [*]f64 {
    const m = @min(n, echo_buf.len);
    for (echo_buf[0..m], 0..) |*e, k| e.* = @floatFromInt(k);
    return &echo_buf;
}

comptime {
    if (platform.is_web) {
        @export(&setBench, .{ .name = "f2d_set_bench" });
        @export(&noopExport, .{ .name = "f2d_noop" });
        @export(&echoExport, .{ .name = "f2d_echo" });
    }
}

fn appFrame() !dvui.App.Result {
    if (bench.isFinished()) return .close;
    if (platform.is_web) {
        if (dvui.wasmFileUploaded(web_open_id)) |f| {
            if (f.readData(std.heap.page_allocator)) |data| {
                defer std.heap.page_allocator.free(data);
                app.loadJson(data);
            } else |_| {}
        }
    }

    {
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
        defer root.deinit();
        toolbar();
        {
            var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer body.deinit();
            canvasPane();
            {
                var side = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .vertical, .min_size_content = .{ .w = 430 } });
                defer side.deinit();
                table.show(&app);
            }
        }
        statusBar();
    }
    genDialog();
    return .ok;
}

fn canvasPane() void {
    var cb = dvui.box(@src(), .{}, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = .{ .r = 22, .g = 24, .b = 30, .a = 255 } },
        .min_size_content = .{ .w = 300, .h = 200 },
        .name = "canvas",
    });
    defer cb.deinit();
    const rs = cb.data().contentRectScale();
    const g = canvas.Geometry{ .r = rs.r, .ps = rs.s };
    if (app.fit_pending and g.r.w > 50 and g.r.h > 50 and platform.bench_mode == .none) {
        // keep fitting until the user pans or zooms (layout settles over the first frames)
        canvas.fitView(&app, g);
        app.fit_pending = true;
    }
    canvas.handleEvents(&app, cb.data(), g);
    if (app.dirty) app.resolve(app.case);
    bench.tick(&app, g);
    canvas.draw(&app, g);
}

fn toolbar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
    defer bar.deinit();

    if (dvui.button(@src(), "Open", .{}, .{})) openModel();
    if (dvui.button(@src(), "Save", .{}, .{})) saveModel();
    if (dvui.button(@src(), "Generate...", .{}, .{})) app.show_gen = true;
    if (dvui.button(@src(), "Solve", .{}, .{})) app.resolve(null); // BENCH-EDIT:ui

    // load case selector
    const lcs = app.model.load_cases;
    if (lcs.len > 0) {
        const arena = dvui.currentWindow().arena();
        if (arena.alloc([]const u8, lcs.len)) |names| {
            for (lcs, 0..) |lc, k| names[k] = lc.id;
            var choice: usize = @min(app.case, lcs.len - 1);
            if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .min_size_content = .{ .w = 40 } })) app.setCase(choice);
        } else |_| {}
    }

    _ = dvui.checkbox(@src(), &app.show_deflected, "Deflected", .{ .gravity_y = 0.5 });
    _ = dvui.slider(@src(), .{ .fraction = &app.defl_slider }, .{ .min_size_content = .{ .w = 80 }, .gravity_y = 0.5 });
    dvui.label(@src(), "x{d:.1}", .{canvas.deflectionMagnification(&app)}, .{ .gravity_y = 0.5 });
    _ = dvui.checkbox(@src(), &app.show_moment, "Moment", .{ .gravity_y = 0.5 });
    _ = dvui.slider(@src(), .{ .fraction = &app.moment_slider }, .{ .min_size_content = .{ .w = 80 }, .gravity_y = 0.5 });
    _ = dvui.checkbox(@src(), &app.color_by_moment, "Color by |M|", .{ .gravity_y = 0.5 });
    if (dvui.button(@src(), "Fit", .{}, .{})) app.fit_pending = true;
}

fn statusBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(2) });
    defer bar.deinit();
    if (app.err_len > 0) {
        dvui.labelNoFmt(@src(), app.errText(), .{}, .{ .color_text = .{ .color = .{ .r = 240, .g = 90, .b = 90, .a = 255 } } });
    } else {
        dvui.labelNoFmt(@src(), app.status[0..app.status_len], .{}, .{});
    }
}

fn genDialog() void {
    if (!app.show_gen) return;
    var fw = dvui.floatingWindow(@src(), .{ .modal = true, .open_flag = &app.show_gen }, .{ .min_size_content = .{ .w = 260, .h = 120 } });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Generate frame", "", &app.show_gen));
    _ = dvui.sliderEntry(@src(), "Bays {d:0.0}", .{ .value = &app.gen_bays, .min = 1, .max = 200, .interval = 1 }, .{ .expand = .horizontal });
    _ = dvui.sliderEntry(@src(), "Stories {d:0.0}", .{ .value = &app.gen_stories, .min = 1, .max = 200, .interval = 1 }, .{ .expand = .horizontal });
    if (dvui.button(@src(), "Generate", .{}, .{ .expand = .horizontal })) {
        app.generate(@intFromFloat(app.gen_bays), @intFromFloat(app.gen_stories));
        app.show_gen = false;
    }
}

// ---- open / save

fn openModel() void {
    if (platform.is_web) {
        dvui.dialogWasmFileOpen(web_open_id, .{ .accept = ".json" });
        return;
    }
    const gpa = std.heap.page_allocator;
    const path = (dvui.dialogNativeFileOpen(gpa, .{ .title = "Open model", .filters = &.{"*.json"}, .filter_description = "Model JSON" }) catch return) orelse return;
    defer gpa.free(path);
    const text = platform.readFile(gpa, path) catch {
        app.setStatus("cannot read {s}", .{path});
        return;
    };
    defer gpa.free(text);
    app.loadJson(text);
}

fn saveModel() void {
    const gpa = std.heap.page_allocator;
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    model_mod.write(&out.writer, &app.model) catch return;
    if (platform.is_web) {
        platform.download("model.json", out.written());
        return;
    }
    const path = (dvui.dialogNativeFileSave(gpa, .{ .title = "Save model", .filters = &.{"*.json"}, .filter_description = "Model JSON" }) catch return) orelse return;
    defer gpa.free(path);
    platform.writeFile(path, out.written()) catch app.setStatus("cannot write {s}", .{path});
}

const web_open_id: dvui.Id = @enumFromInt(0x46324431);
