//! `frame2d` CLI (SPEC 5.3): solve / gen / bench. Exit 0 ok, 2 model error, 1 anything else.
const std = @import("std");
const engine = @import("engine.zig");
const model = engine.model;
const report = @import("report.zig");
const Counting = @import("counting.zig").Counting;

var g_io: std.Io = undefined;

fn clockMs() f64 {
    const t = std.Io.Clock.awake.now(g_io);
    return @as(f64, @floatFromInt(t.nanoseconds)) / 1e6;
}

fn usage() u8 {
    std.debug.print(
        \\usage: frame2d solve <model.json> [-o results.json]
        \\       frame2d gen <B> <S> [-o model.json]
        \\       frame2d bench <B> <S> [--reps N]
        \\
    , .{});
    return 1;
}

pub fn main(init: std.process.Init) u8 {
    g_io = init.io;
    return run(init) catch |e| {
        std.debug.print("frame2d: {s}\n", .{@errorName(e)});
        return 1;
    };
}

fn emit(io: std.Io, out_path: ?[]const u8, bytes: []const u8) !void {
    if (out_path) |p| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
    }
}

fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();
    const cmd = args[1];

    var out_path: ?[]const u8 = null;
    var reps: usize = 1;
    var pos: std.ArrayList([]const u8) = .empty;
    var k: usize = 2;
    while (k < args.len) : (k += 1) {
        const a = args[k];
        if (std.mem.eql(u8, a, "-o") and k + 1 < args.len) {
            k += 1;
            out_path = args[k];
        } else if (std.mem.eql(u8, a, "--reps") and k + 1 < args.len) {
            k += 1;
            reps = try std.fmt.parseInt(usize, args[k], 10);
        } else try pos.append(arena, a);
    }

    var aw: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer aw.deinit();

    if (std.mem.eql(u8, cmd, "gen")) {
        if (pos.items.len != 2) return usage();
        const m = try model.gen(arena, try std.fmt.parseInt(u32, pos.items[0], 10), try std.fmt.parseInt(u32, pos.items[1], 10));
        try model.write(&aw.writer, m);
        try emit(io, out_path, aw.written());
        return 0;
    }
    if (std.mem.eql(u8, cmd, "solve")) {
        if (pos.items.len != 1) return usage();
        const text = try std.Io.Dir.cwd().readFileAlloc(io, pos.items[0], arena, .limited(1 << 30));
        const m = model.parse(arena, text) catch |e| {
            if (e == error.InvalidModelJson) std.debug.print("frame2d: invalid model JSON\n", .{});
            return 1;
        };
        var counting = Counting{ .child = std.heap.smp_allocator };
        const o = try engine.solve(counting.allocator(), m, .{ .clock = clockMs });
        switch (o) {
            .err => |e| {
                try report.writeError(&aw.writer, e);
                try std.Io.File.stdout().writeStreamingAll(io, aw.written());
                return 2;
            },
            .ok => |r0| {
                var r = r0;
                r.stats.alloc_count = counting.count;
                r.stats.alloc_bytes = counting.bytes;
                r.stats.peak_heap_bytes = counting.peak;
                try report.writeResults(&aw.writer, m, r);
                try emit(io, out_path, aw.written());
                return 0;
            },
        }
    }
    if (std.mem.eql(u8, cmd, "bench")) {
        if (pos.items.len != 2) return usage();
        const m = try model.gen(arena, try std.fmt.parseInt(u32, pos.items[0], 10), try std.fmt.parseInt(u32, pos.items[1], 10));
        reps = @max(reps, 1);
        const asm_ms = try arena.alloc(f64, reps);
        const fac_ms = try arena.alloc(f64, reps);
        const sol_ms = try arena.alloc(f64, reps);
        var last: engine.Stats = .{};
        for (0..reps) |rep| {
            var counting = Counting{ .child = std.heap.smp_allocator };
            var ra = std.heap.ArenaAllocator.init(counting.allocator());
            defer ra.deinit();
            const o = try engine.solve(counting.allocator(), m, .{ .clock = clockMs });
            switch (o) {
                .err => |e| {
                    try report.writeError(&aw.writer, e);
                    try std.Io.File.stdout().writeStreamingAll(io, aw.written());
                    return 2;
                },
                .ok => |r| {
                    last = r.stats;
                    last.alloc_count = counting.count;
                    last.alloc_bytes = counting.bytes;
                    last.peak_heap_bytes = counting.peak;
                    asm_ms[rep] = r.stats.assemble_ms;
                    fac_ms[rep] = r.stats.factor_ms;
                    sol_ms[rep] = r.stats.solve_ms;
                    freeResults(counting.allocator(), r);
                },
            }
        }
        last.assemble_ms = median(asm_ms);
        last.factor_ms = median(fac_ms);
        last.solve_ms = median(sol_ms);
        try aw.writer.print("{{\"reps\":{d},\"stats\":", .{reps});
        try report.writeStats(&aw.writer, last);
        try aw.writer.writeAll("}\n");
        try std.Io.File.stdout().writeStreamingAll(io, aw.written());
        return 0;
    }
    return usage();
}

fn freeResults(a: std.mem.Allocator, r: engine.Results) void {
    for (r.cases) |c| {
        a.free(c.disp);
        a.free(c.react);
        a.free(c.end_forces);
        a.free(c.stations);
    }
    a.free(r.cases);
    a.free(r.node_src);
    a.free(r.member_src);
    a.free(r.restrained);
    a.free(r.supported);
    a.free(r.auto_restrained);
}

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const n = xs.len;
    return if (n % 2 == 1) xs[n / 2] else (xs[n / 2 - 1] + xs[n / 2]) / 2;
}
