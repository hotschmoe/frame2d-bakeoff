//! frame2d HTTP server (SPEC 5.4): std.http over std.Io.net, one thread per connection, SQLite store.
const std = @import("std");
const engine = @import("engine.zig");
const model = engine.model;
const report = @import("report.zig");
const sweep = @import("sweep.zig");
const Store = @import("store.zig").Store;

const body_limit = 64 * 1024 * 1024;
const frame2d_header_line = "x-frame2d: a"; // BENCH-EDIT:server
const frame2d_header = frame2d_header_line["x-frame2d: ".len..];

const Ctx = struct {
    io: std.Io,
    store: Store,
};

pub fn main(init: std.process.Init) u8 {
    run(init) catch |e| {
        std.debug.print("frame2d-server: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const addr_text = init.environ_map.get("FRAME2D_ADDR") orelse "127.0.0.1:8080";
    const colon = std.mem.findScalarLast(u8, addr_text, ':') orelse return error.BadAddress;
    const port = try std.fmt.parseInt(u16, addr_text[colon + 1 ..], 10);
    var host = addr_text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1]; // [::1]:8080
    const addr = try std.Io.net.IpAddress.parse(host, port);
    const db_path = try init.arena.allocator().dupeSentinel(u8, init.environ_map.get("FRAME2D_DB") orelse "frame2d-models.db", 0);

    var ctx = Ctx{ .io = io, .store = try Store.open(io, db_path) };
    var server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 1024 });
    defer server.deinit(io);
    std.debug.print("frame2d-server listening on {s}\n", .{addr_text});
    while (true) {
        const stream = server.accept(io) catch |e| {
            std.debug.print("accept: {s}\n", .{@errorName(e)});
            continue;
        };
        const t = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, handleConn, .{ &ctx, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn handleConn(ctx: *Ctx, stream: std.Io.net.Stream) void {
    const io = ctx.io;
    defer stream.close(io);
    const rbuf = std.heap.smp_allocator.alloc(u8, 64 * 1024) catch return;
    defer std.heap.smp_allocator.free(rbuf);
    const wbuf = std.heap.smp_allocator.alloc(u8, 64 * 1024) catch return;
    defer std.heap.smp_allocator.free(wbuf);
    var sr = stream.reader(io, rbuf);
    var sw = stream.writer(io, wbuf);
    var srv = std.http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = srv.receiveHead() catch return;
        const keep = req.head.keep_alive;
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const reuse = handle(arena.allocator(), ctx, &req) catch return;
        if (!keep or !reuse) return;
    }
}

/// `close`: answer with `connection: close` and drop the connection (the request body was not
/// consumed, so the stream is not at a request boundary).
const Reply = struct { status: std.http.Status, body: []const u8, close: bool = false };

const too_large: Reply = .{ .status = .payload_too_large, .body = "{\"error\":\"too_large\",\"detail\":\"body over 64 MB\"}", .close = true };
const bad_body: Reply = .{ .status = .bad_request, .body = "{\"error\":\"bad_request\",\"detail\":\"could not read the request body\"}", .close = true };

/// Returns whether the connection may be reused.
fn respond(req: *std.http.Server.Request, r: Reply) !bool {
    try req.respond(r.body, .{
        .status = r.status,
        .keep_alive = !r.close,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-frame2d", .value = frame2d_header },
        },
    });
    return !r.close;
}

fn handle(a: std.mem.Allocator, ctx: *Ctx, req: *std.http.Server.Request) !bool {
    const method = req.head.method;
    const target = try a.dupe(u8, req.head.target);
    var body: []const u8 = "";
    if (method == .POST or method == .PUT) {
        if (req.head.content_length) |n| if (n > body_limit) return respond(req, too_large);
        const rbuf = try a.alloc(u8, 64 * 1024);
        const r = req.readerExpectContinue(rbuf) catch return respond(req, bad_body);
        body = r.allocRemaining(a, .limited(body_limit + 1)) catch |e| switch (e) {
            error.StreamTooLong => return respond(req, too_large),
            error.OutOfMemory => return e,
            error.ReadFailed => return respond(req, bad_body),
        };
    }
    const reply = route(a, ctx, method, target, body) catch |e| switch (e) {
        error.OutOfMemory => Reply{ .status = .internal_server_error, .body = "{\"error\":\"internal\",\"detail\":\"out of memory\"}" },
        else => Reply{ .status = .internal_server_error, .body = try std.fmt.allocPrint(a, "{{\"error\":\"internal\",\"detail\":\"{s}\"}}", .{@errorName(e)}) },
    };
    return respond(req, reply);
}

fn badJson(a: std.mem.Allocator) !Reply {
    _ = a;
    return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\",\"detail\":\"request body is not a valid model\"}" };
}

fn solveReply(a: std.mem.Allocator, text: []const u8) !Reply {
    const m = model.parse(a, text) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return badJson(a),
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    const o = try engine.solve(a, m, .{});
    switch (o) {
        .err => |e| {
            try report.writeError(&aw.writer, e);
            return .{ .status = .unprocessable_entity, .body = aw.written() };
        },
        .ok => |r| {
            try report.writeResults(&aw.writer, m, r);
            return .{ .status = .ok, .body = aw.written() };
        },
    }
}

const SweepReq = struct {
    model: ?std.json.Value = null,
    model_id: ?[]const u8 = null,
    variants: usize = 1000,
    beam_I_scale: [2]f64 = .{ 0.5, 2.0 },
};

fn route(a: std.mem.Allocator, ctx: *Ctx, method: std.http.Method, target: []const u8, body: []const u8) !Reply {
    const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
    if (method == .GET and std.mem.eql(u8, path, "/health")) return .{ .status = .ok, .body = "{\"ok\":true}" };
    if (method == .POST and std.mem.eql(u8, path, "/solve")) return solveReply(a, body);
    if (method == .POST and std.mem.eql(u8, path, "/models")) {
        _ = model.parse(a, body) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return badJson(a),
        };
        var raw: [8]u8 = undefined;
        ctx.io.random(&raw);
        const id = try std.fmt.allocPrint(a, "{x}", .{std.mem.readInt(u64, &raw, .little)});
        try ctx.store.put(id, body);
        return .{ .status = .created, .body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{id}) };
    }
    if (std.mem.startsWith(u8, path, "/models/")) {
        const rest = path["/models/".len..];
        if (method == .GET and std.mem.findScalar(u8, rest, '/') == null) {
            const b = try ctx.store.get(a, rest) orelse return notFound();
            return .{ .status = .ok, .body = b };
        }
        if (method == .POST and std.mem.endsWith(u8, rest, "/solve")) {
            const id = rest[0 .. rest.len - "/solve".len];
            const b = try ctx.store.get(a, id) orelse return notFound();
            return solveReply(a, b);
        }
    }
    if (method == .POST and std.mem.eql(u8, path, "/sweep")) {
        const req = std.json.parseFromSliceLeaky(SweepReq, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return badJson(a);
        var m: model.Model = undefined;
        if (req.model) |v| {
            m = std.json.parseFromValueLeaky(model.Model, a, v, .{ .ignore_unknown_fields = true }) catch return badJson(a);
        } else if (req.model_id) |id| {
            const b = try ctx.store.get(a, id) orelse return notFound();
            m = model.parse(a, b) catch return badJson(a);
        } else return badJson(a);
        const res = try sweep.run(a, a, m, req.variants, req.beam_I_scale[0], req.beam_I_scale[1]);
        var aw: std.Io.Writer.Allocating = .init(a);
        const w = &aw.writer;
        switch (res) {
            .err => |e| {
                try report.writeError(w, e);
                return .{ .status = .unprocessable_entity, .body = aw.written() };
            },
            .ok => |vs| {
                var env_drift: f64 = -std.math.inf(f64);
                var env_m: f64 = 0;
                try w.writeAll("{\"variants\":[");
                for (vs, 0..) |v, k| {
                    if (k > 0) try w.writeByte(',');
                    try w.writeAll("{\"scale\":");
                    try model.writeNum(w, v.scale);
                    try w.writeAll(",\"roof_drift_W\":");
                    try model.writeNum(w, v.roof_drift_W);
                    try w.writeAll(",\"max_abs_M\":");
                    try model.writeNum(w, v.max_abs_M);
                    try w.writeByte('}');
                    if (!std.math.isNan(v.roof_drift_W)) env_drift = @max(env_drift, v.roof_drift_W);
                    env_m = @max(env_m, v.max_abs_M);
                }
                if (vs.len == 0) env_drift = 0;
                if (std.math.isInf(env_drift)) env_drift = std.math.nan(f64); // no case "W" -> null
                try w.writeAll("],\"envelope\":{\"max_roof_drift_W\":");
                try model.writeNum(w, env_drift);
                try w.writeAll(",\"max_abs_M\":");
                try model.writeNum(w, env_m);
                try w.writeAll("}}\n");
                return .{ .status = .ok, .body = aw.written() };
            },
        }
    }
    return notFound();
}

fn notFound() Reply {
    return .{ .status = .not_found, .body = "{\"error\":\"not_found\",\"detail\":\"no such route or model\"}" };
}
