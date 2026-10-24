//! frame2d-server (SPEC 5.4): std.http.Server, one OS thread per connection, SQLite model store,
//! sweeps fan out over all cores inside the engine.
const std = @import("std");
const engine = @import("engine");
const sqlite = @import("sqlite.zig");

const http = std.http;
const max_body = 64 * 1024 * 1024;
/// Response header carried on every reply, written as "name: value".
const server_tag = "x-frame2d: a"; // BENCH-EDIT:server

const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    store: sqlite.Store,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const addr_text = init.environ_map.get("FRAME2D_ADDR") orelse "127.0.0.1:8080";
    const db_name = init.environ_map.get("FRAME2D_DB") orelse "frame2d.db";
    const db_path = try gpa.allocSentinel(u8, db_name.len, 0);
    defer gpa.free(db_path);
    @memcpy(db_path, db_name);

    const colon = std.mem.lastIndexOfScalar(u8, addr_text, ':') orelse return error.BadAddress;
    const port = try std.fmt.parseInt(u16, addr_text[colon + 1 ..], 10);
    const address = try std.Io.net.IpAddress.parse(addr_text[0..colon], port);

    var store = try sqlite.Store.open(db_path);
    defer store.close();
    var ctx: Ctx = .{ .io = io, .gpa = gpa, .store = store };

    var listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 1024 });
    defer listener.deinit(io);
    std.debug.print("frame2d-server listening on {s}\n", .{addr_text});

    while (true) {
        const stream = listener.accept(io) catch |e| {
            std.debug.print("accept failed: {t}\n", .{e});
            continue;
        };
        const t = std.Thread.spawn(.{}, connection, .{ &ctx, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn connection(ctx: *Ctx, stream: std.Io.net.Stream) void {
    defer stream.close(ctx.io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(ctx.io, &rbuf);
    var writer = stream.writer(ctx.io, &wbuf);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var req = server.receiveHead() catch return;
        handle(ctx, &req) catch return;
        if (!req.head.keep_alive) return;
    }
}

const Reply = struct {
    status: http.Status = .ok,
    body: []const u8,
};

fn handle(ctx: *Ctx, req: *http.Server.Request) !void {
    const gpa = ctx.gpa;
    // The target lives in the read buffer, which the body reader reuses: copy it first.
    var path_buf: [512]u8 = undefined;
    const target = req.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (path_end > path_buf.len) return respondText(req, .uri_too_long, "{\"error\":\"bad_request\",\"detail\":\"path too long\"}");
    @memcpy(path_buf[0..path_end], target[0..path_end]);
    const path = path_buf[0..path_end];
    const method = req.head.method;

    var body: []u8 = &.{};
    if (method == .POST or method == .PUT) {
        var body_buf: [8192]u8 = undefined;
        const br = req.readerExpectContinue(&body_buf) catch return error.HttpExpect;
        body = br.allocRemaining(gpa, .limited(max_body)) catch |e| switch (e) {
            error.StreamTooLong => return respondText(req, .payload_too_large, "{\"error\":\"too_large\",\"detail\":\"body exceeds 64 MB\"}"),
            else => return e,
        };
    }
    defer gpa.free(body);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const reply = route(ctx, method, path, body, &out) catch |e| switch (e) {
        error.OutOfMemory => Reply{ .status = .internal_server_error, .body = "{\"error\":\"oom\",\"detail\":\"out of memory\"}" },
        else => Reply{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"detail\":\"internal error\"}" },
    };
    try respondText(req, reply.status, reply.body);
}

fn respondText(req: *http.Server.Request, status: http.Status, body: []const u8) !void {
    const sep = std.mem.indexOf(u8, server_tag, ": ").?;
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = server_tag[0..sep], .value = server_tag[sep + 2 ..] },
    };
    try req.respond(body, .{ .status = status, .extra_headers = &headers });
}

const not_found: Reply = .{ .status = .not_found, .body = "{\"error\":\"not_found\",\"detail\":\"no such route\"}" };

fn route(ctx: *Ctx, method: http.Method, path: []const u8, body: []const u8, out: *std.Io.Writer.Allocating) !Reply {
    if (method == .GET and std.mem.eql(u8, path, "/health")) return .{ .body = "{\"ok\":true}" };
    if (method == .POST and std.mem.eql(u8, path, "/solve")) return solveText(ctx, body, out);
    if (method == .POST and std.mem.eql(u8, path, "/sweep")) return sweepRequest(ctx, body, out);
    if (method == .POST and std.mem.eql(u8, path, "/models")) return storeModel(ctx, body, out);
    const prefix = "/models/";
    if (std.mem.startsWith(u8, path, prefix)) {
        const rest = path[prefix.len..];
        if (method == .GET) {
            const id = std.fmt.parseInt(i64, rest, 10) catch return not_found;
            const text = (try ctx.store.get(ctx.gpa, id)) orelse return not_found;
            defer ctx.gpa.free(text);
            try out.writer.writeAll(text);
            return .{ .body = out.written() };
        }
        const solve_suffix = "/solve";
        if (method == .POST and std.mem.endsWith(u8, rest, solve_suffix)) {
            const id = std.fmt.parseInt(i64, rest[0 .. rest.len - solve_suffix.len], 10) catch return not_found;
            const text = (try ctx.store.get(ctx.gpa, id)) orelse return not_found;
            defer ctx.gpa.free(text);
            return solveText(ctx, text, out);
        }
    }
    return not_found;
}

fn modelErrorReply(diag: *const engine.Diag, out: *std.Io.Writer.Allocating) !Reply {
    out.clearRetainingCapacity();
    try engine.results_json.writeError(&out.writer, diag);
    return .{ .status = .unprocessable_entity, .body = out.written() };
}

fn solveText(ctx: *Ctx, text: []const u8, out: *std.Io.Writer.Allocating) !Reply {
    var diag: engine.Diag = .{};
    var m = engine.model_json.parse(ctx.gpa, text, &diag) catch |e| switch (e) {
        error.Model => return modelErrorReply(&diag, out),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer m.deinit();
    return solveModel(ctx, &m, out);
}

fn solveModel(ctx: *Ctx, m: *const engine.Model, out: *std.Io.Writer.Allocating) !Reply {
    var diag: engine.Diag = .{};
    var s = engine.Solver.init(ctx.gpa);
    defer s.deinit();
    s.solve(m, m.sections, std.math.maxInt(u32), &diag) catch |e| switch (e) {
        error.Model => return modelErrorReply(&diag, out),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try engine.results_json.writeResults(&out.writer, m, &s, null);
    return .{ .body = out.written() };
}

fn storeModel(ctx: *Ctx, text: []const u8, out: *std.Io.Writer.Allocating) !Reply {
    var diag: engine.Diag = .{};
    var m = engine.model_json.parse(ctx.gpa, text, &diag) catch |e| switch (e) {
        error.Model => return modelErrorReply(&diag, out),
        error.OutOfMemory => return error.OutOfMemory,
    };
    m.deinit();
    const id = try ctx.store.insert(text);
    try out.writer.print("{{\"id\":\"{d}\"}}", .{id});
    return .{ .body = out.written() };
}

const SweepRequest = struct {
    model: ?std.json.Value = null,
    model_id: ?[]const u8 = null,
    variants: usize = 1,
    beam_I_scale: [2]f64 = .{ 1, 1 },
};

fn sweepRequest(ctx: *Ctx, body: []const u8, out: *std.Io.Writer.Allocating) !Reply {
    var scratch = std.heap.ArenaAllocator.init(ctx.gpa);
    defer scratch.deinit();
    const bad: Reply = .{ .status = .bad_request, .body = "{\"error\":\"bad_request\",\"detail\":\"invalid sweep request\"}" };
    const req = std.json.parseFromSliceLeaky(SweepRequest, scratch.allocator(), body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return bad,
    };
    if (req.variants == 0 or req.variants > 1_000_000) return bad;
    var diag: engine.Diag = .{};
    const m = if (req.model) |v|
        engine.model_json.parseValue(ctx.gpa, v, &diag)
    else if (req.model_id) |id_text| blk: {
        const id = std.fmt.parseInt(i64, id_text, 10) catch return not_found;
        const text = (try ctx.store.get(ctx.gpa, id)) orelse return not_found;
        defer ctx.gpa.free(text);
        break :blk engine.model_json.parse(ctx.gpa, text, &diag);
    } else return bad;
    var model = m catch |e| switch (e) {
        error.Model => return modelErrorReply(&diag, out),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer model.deinit();
    const result = engine.sweep.run(ctx.gpa, &model, req.variants, req.beam_I_scale[0], req.beam_I_scale[1], &diag) catch |e| switch (e) {
        error.Model => return modelErrorReply(&diag, out),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ctx.gpa.free(result.variants);
    try engine.sweep.writeJson(&out.writer, result);
    return .{ .body = out.written() };
}
