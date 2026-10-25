//! frame2d HTTP server (SPEC 5.4) on std.http.Server, one OS thread per connection.
const std = @import("std");
const http = std.http;
const engine = @import("engine");
const model_mod = engine.model;
const solver = engine.solver;
const report = engine.report;
const sweep = @import("sweep.zig");
const Store = @import("store.zig").Store;

const max_body = 64 * 1024 * 1024;
const frame2d_header = "x-frame2d: a"; // BENCH-EDIT:server

var g_io: std.Io = undefined;

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(g_io).nanoseconds);
}

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: Store,
};

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    solver.clock_ns = nowNs;
    const gpa = std.heap.smp_allocator;
    const addr_text = init.environ_map.get("FRAME2D_ADDR") orelse "127.0.0.1:8080";
    const colon = std.mem.findScalarLast(u8, addr_text, ':') orelse return error.BadAddress;
    const port = try std.fmt.parseInt(u16, addr_text[colon + 1 ..], 10);
    const address = try std.Io.net.IpAddress.parse(addr_text[0..colon], port);

    const db_path = init.environ_map.get("FRAME2D_DB") orelse ":memory:";
    const db_z = try gpa.dupeSentinel(u8, db_path, 0);
    const store = try Store.open(db_z);

    var app = App{ .gpa = gpa, .io = g_io, .store = store };
    var listener = try address.listen(g_io, .{ .reuse_address = true, .kernel_backlog = 1024 });
    defer listener.deinit(g_io);
    var out_buf: [128]u8 = undefined;
    var out = std.Io.File.stderr().writer(g_io, &out_buf);
    try out.interface.print("frame2d server listening on {s}\n", .{addr_text});
    try out.interface.flush();

    while (true) {
        const stream = listener.accept(g_io) catch |e| {
            if (e == error.Canceled) return;
            continue;
        };
        const t = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, serveConnection, .{ &app, stream }) catch {
            stream.close(g_io);
            continue;
        };
        t.detach();
    }
}

fn serveConnection(app: *App, stream: std.Io.net.Stream) void {
    defer stream.close(app.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    var sr = stream.reader(app.io, &rbuf);
    var sw = stream.writer(app.io, &wbuf);
    var srv = http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        handle(app, &req) catch return;
    }
}

fn respond(req: *http.Server.Request, status: http.Status, body: []const u8) !void {
    const colon = comptime std.mem.indexOf(u8, frame2d_header, ": ").?;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = frame2d_header[0..colon], .value = frame2d_header[colon + 2 ..] },
    };
    try req.respond(body, .{ .status = status, .extra_headers = &headers });
}

/// Streams the JSON body straight to the socket (chunked): no buffering of multi-MB results per request.
fn respondResults(req: *http.Server.Request, m: *const model_mod.Model, res: *const solver.Results) !void {
    const colon = comptime std.mem.indexOf(u8, frame2d_header, ": ").?;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = frame2d_header[0..colon], .value = frame2d_header[colon + 2 ..] },
    };
    var buf: [32 * 1024]u8 = undefined;
    var bw = try req.respondStreaming(&buf, .{ .respond_options = .{ .status = .ok, .extra_headers = &headers } });
    try report.writeResults(&bw.writer, m, res);
    try bw.end();
}

fn respondError(req: *http.Server.Request, status: http.Status, code: []const u8, detail: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const ok = blk: {
        w.writeAll("{\"error\":") catch break :blk false;
        std.json.Stringify.encodeJsonString(code, .{}, &w) catch break :blk false;
        w.writeAll(",\"detail\":") catch break :blk false;
        std.json.Stringify.encodeJsonString(detail, .{}, &w) catch break :blk false;
        w.writeByte('}') catch break :blk false;
        break :blk true;
    };
    try respond(req, status, if (ok) w.buffered() else "{\"error\":\"bad_request\"}");
}

fn respondModelError(req: *http.Server.Request, info: *const solver.ErrorInfo) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    report.writeError(&w, info) catch {};
    try respond(req, .unprocessable_entity, w.buffered());
}

fn readBody(app: *App, req: *http.Server.Request) ![]u8 {
    var tmp: [4096]u8 = undefined;
    const reader = try req.readerExpectContinue(&tmp);
    return reader.allocRemaining(app.gpa, .limited(max_body));
}

fn handle(app: *App, req: *http.Server.Request) !void {
    var target_buf: [512]u8 = undefined;
    const raw_target = req.head.target;
    if (raw_target.len > target_buf.len) return respondError(req, .uri_too_long, "bad_request", "target too long");
    @memcpy(target_buf[0..raw_target.len], raw_target);
    const target = target_buf[0..raw_target.len];
    const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
    const method = req.head.method;

    if (std.mem.eql(u8, path, "/health") and method == .GET) {
        return respond(req, .ok, "{\"ok\":true}");
    }
    if (std.mem.eql(u8, path, "/solve") and method == .POST) {
        const body = readBody(app, req) catch return respondError(req, .bad_request, "bad_request", "cannot read body");
        defer app.gpa.free(body);
        return solveAndRespond(app, req, body);
    }
    if (std.mem.eql(u8, path, "/models") and method == .POST) {
        const body = readBody(app, req) catch return respondError(req, .bad_request, "bad_request", "cannot read body");
        defer app.gpa.free(body);
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        _ = model_mod.parse(arena.allocator(), body) catch return respondError(req, .bad_request, "bad_request", "invalid model json");
        const id = app.store.put(body) catch return respondError(req, .internal_server_error, "internal", "store failure");
        var buf: [64]u8 = undefined;
        return respond(req, .ok, try std.fmt.bufPrint(&buf, "{{\"id\":\"{d}\"}}", .{id}));
    }
    if (std.mem.startsWith(u8, path, "/models/")) {
        var rest = path["/models/".len..];
        const solve_suffix = std.mem.endsWith(u8, rest, "/solve");
        if (solve_suffix) rest = rest[0 .. rest.len - "/solve".len];
        const id = std.fmt.parseInt(i64, rest, 10) catch return respondError(req, .not_found, "not_found", "unknown model");
        if (solve_suffix and method == .POST) {
            _ = readBody(app, req) catch {};
            const text = (app.store.get(app.gpa, id) catch return respondError(req, .internal_server_error, "internal", "store failure")) orelse
                return respondError(req, .not_found, "not_found", "unknown model");
            defer app.gpa.free(text);
            return solveAndRespond(app, req, text);
        }
        if (!solve_suffix and method == .GET) {
            const text = (app.store.get(app.gpa, id) catch return respondError(req, .internal_server_error, "internal", "store failure")) orelse
                return respondError(req, .not_found, "not_found", "unknown model");
            defer app.gpa.free(text);
            return respond(req, .ok, text);
        }
    }
    if (std.mem.eql(u8, path, "/sweep") and method == .POST) {
        const body = readBody(app, req) catch return respondError(req, .bad_request, "bad_request", "cannot read body");
        defer app.gpa.free(body);
        return sweepAndRespond(app, req, body);
    }
    return respondError(req, .not_found, "not_found", "no such route");
}

fn solveAndRespond(app: *App, req: *http.Server.Request, body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    var m = model_mod.parse(arena.allocator(), body) catch return respondError(req, .bad_request, "bad_request", "invalid model json");
    var info: solver.ErrorInfo = .{};
    var res = solver.solve(app.gpa, &m, &info) catch |e| switch (e) {
        error.ModelError => return respondModelError(req, &info),
        error.OutOfMemory => return respondError(req, .internal_server_error, "internal", "out of memory"),
    };
    defer res.deinit();
    return respondResults(req, &m, &res);
}

const SweepRequest = struct {
    model: ?model_mod.Model = null,
    model_id: ?[]const u8 = null,
    variants: usize = 1,
    beam_I_scale: [2]f64 = .{ 1, 1 },
};

fn sweepAndRespond(app: *App, req: *http.Server.Request, body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sr = std.json.parseFromSliceLeaky(SweepRequest, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return respondError(req, .bad_request, "bad_request", "invalid sweep request");
    var m: model_mod.Model = undefined;
    if (sr.model) |mm| {
        m = mm;
    } else if (sr.model_id) |id_text| {
        const id = std.fmt.parseInt(i64, id_text, 10) catch return respondError(req, .not_found, "not_found", "unknown model");
        const text = (app.store.get(app.gpa, id) catch return respondError(req, .internal_server_error, "internal", "store failure")) orelse
            return respondError(req, .not_found, "not_found", "unknown model");
        defer app.gpa.free(text);
        m = model_mod.parse(a, text) catch return respondError(req, .bad_request, "bad_request", "invalid stored model");
    } else {
        return respondError(req, .bad_request, "bad_request", "model or model_id required");
    }
    if (sr.variants == 0 or sr.variants > 1_000_000) return respondError(req, .bad_request, "bad_request", "bad variants");

    var info: solver.ErrorInfo = .{};
    const variants = sweep.run(app.gpa, &m, sr.variants, sr.beam_I_scale[0], sr.beam_I_scale[1], &info) catch |e| switch (e) {
        error.ModelError => return respondModelError(req, &info),
        error.OutOfMemory => return respondError(req, .internal_server_error, "internal", "out of memory"),
    };
    defer app.gpa.free(variants);
    var out = std.Io.Writer.Allocating.init(app.gpa);
    defer out.deinit();
    sweep.write(&out.writer, variants) catch return respondError(req, .internal_server_error, "internal", "out of memory");
    return respond(req, .ok, out.written());
}
