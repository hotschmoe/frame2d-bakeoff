//! frame2d CLI (SPEC 5.3): solve | gen | bench
const std = @import("std");
const engine = @import("engine");
const model_mod = engine.model;
const solver = engine.solver;
const report = engine.report;

var g_io: std.Io = undefined;

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(g_io).nanoseconds);
}

const usage =
    \\usage:
    \\  frame2d solve <model.json> [-o results.json]
    \\  frame2d gen <B> <S> [-o model.json]
    \\  frame2d bench <B> <S> [--reps N]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    g_io = init.io;
    solver.clock_ns = nowNs;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stderr_buf: [512]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(g_io, &stderr_buf);
    const ew = &stderr_w.interface;
    defer ew.flush() catch {};

    if (args.len < 2) {
        try ew.writeAll(usage);
        return 1;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "solve")) return cmdSolve(gpa, args[2..], ew);
    if (std.mem.eql(u8, cmd, "gen")) return cmdGen(gpa, args[2..], ew);
    if (std.mem.eql(u8, cmd, "bench")) return cmdBench(gpa, args[2..], ew);
    try ew.writeAll(usage);
    return 1;
}

/// Runs `emit` against the file at `path`, or stdout when null.
fn withOutput(path: ?[]const u8, ctx: anytype) !void {
    var buf: [1 << 16]u8 = undefined;
    if (path) |p| {
        var file = try std.Io.Dir.cwd().createFile(g_io, p, .{});
        defer file.close(g_io);
        var fw = file.writer(g_io, &buf);
        try ctx.emit(&fw.interface);
        try fw.interface.flush();
    } else {
        var fw = std.Io.File.stdout().writer(g_io, &buf);
        try ctx.emit(&fw.interface);
        try fw.interface.flush();
    }
}

const ErrorOut = struct {
    info: *const solver.ErrorInfo,
    fn emit(c: ErrorOut, w: *std.Io.Writer) !void {
        try report.writeError(w, c.info);
    }
};

fn outArg(args: []const [:0]const u8, ew: *std.Io.Writer) !?[]const u8 {
    var out: ?[]const u8 = null;
    var k: usize = 0;
    while (k < args.len) : (k += 1) {
        if (std.mem.eql(u8, args[k], "-o")) {
            if (k + 1 >= args.len) {
                try ew.writeAll("-o needs a path\n");
                return error.BadArgs;
            }
            out = args[k + 1];
            k += 1;
        }
    }
    return out;
}

fn cmdSolve(gpa: std.mem.Allocator, args: []const [:0]const u8, ew: *std.Io.Writer) !u8 {
    if (args.len < 1) {
        try ew.writeAll(usage);
        return 1;
    }
    const out = outArg(args[1..], ew) catch return 1;
    const text = std.Io.Dir.cwd().readFileAlloc(g_io, args[0], gpa, .limited(1 << 30)) catch |e| {
        try ew.print("cannot read {s}: {s}\n", .{ args[0], @errorName(e) });
        return 1;
    };
    defer gpa.free(text);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var m = model_mod.parse(arena.allocator(), text) catch |e| {
        try ew.print("bad model json: {s}\n", .{@errorName(e)});
        return 1;
    };

    var counter = engine.Counting.init(gpa);
    var info: solver.ErrorInfo = .{};
    var res = solver.solve(counter.allocator(), &m, &info) catch |e| switch (e) {
        error.ModelError => {
            try withOutput(null, ErrorOut{ .info = &info });
            return 2;
        },
        error.OutOfMemory => {
            try ew.writeAll("out of memory\n");
            return 1;
        },
    };
    defer res.deinit();
    res.stats.alloc_count = counter.count;
    res.stats.alloc_bytes = counter.bytes;
    res.stats.peak_heap_bytes = counter.peak;

    const Ctx = struct {
        m: *const model_mod.Model,
        res: *const solver.Results,
        fn emit(c: @This(), w: *std.Io.Writer) !void {
            try report.writeResults(w, c.m, c.res);
        }
    };
    withOutput(out, Ctx{ .m = &m, .res = &res }) catch |e| {
        try ew.print("write failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn parseDim(s: []const u8) ?usize {
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn cmdGen(gpa: std.mem.Allocator, args: []const [:0]const u8, ew: *std.Io.Writer) !u8 {
    if (args.len < 2) {
        try ew.writeAll(usage);
        return 1;
    }
    const b = parseDim(args[0]) orelse return 1;
    const s = parseDim(args[1]) orelse return 1;
    const out = outArg(args[2..], ew) catch return 1;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const m = try model_mod.generate(arena.allocator(), b, s);
    const Ctx = struct {
        m: *const model_mod.Model,
        fn emit(c: @This(), w: *std.Io.Writer) !void {
            try model_mod.write(w, c.m);
        }
    };
    withOutput(out, Ctx{ .m = &m }) catch |e| {
        try ew.print("write failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn median(vals: []f64) f64 {
    std.sort.pdq(f64, vals, {}, std.sort.asc(f64));
    return vals[vals.len / 2];
}

fn cmdBench(gpa: std.mem.Allocator, args: []const [:0]const u8, ew: *std.Io.Writer) !u8 {
    if (args.len < 2) {
        try ew.writeAll(usage);
        return 1;
    }
    const b = parseDim(args[0]) orelse return 1;
    const s = parseDim(args[1]) orelse return 1;
    var reps: usize = 5;
    var k: usize = 2;
    while (k + 1 < args.len) : (k += 1) {
        if (std.mem.eql(u8, args[k], "--reps")) reps = parseDim(args[k + 1]) orelse return 1;
    }
    if (reps == 0) reps = 1;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var m = try model_mod.generate(arena.allocator(), b, s);

    const times = try gpa.alloc(f64, reps * 3);
    defer gpa.free(times);
    var last: solver.Stats = .{};
    for (0..reps) |r| {
        var counter = engine.Counting.init(gpa);
        var info: solver.ErrorInfo = .{};
        var res = solver.solve(counter.allocator(), &m, &info) catch |e| {
            if (e == error.ModelError) {
                try withOutput(null, ErrorOut{ .info = &info });
                return 2;
            }
            return 1;
        };
        res.stats.alloc_count = counter.count;
        res.stats.alloc_bytes = counter.bytes;
        res.stats.peak_heap_bytes = counter.peak;
        last = res.stats;
        times[r] = last.assemble_ms;
        times[reps + r] = last.factor_ms;
        times[2 * reps + r] = last.solve_ms;
        res.deinit();
    }
    last.assemble_ms = median(times[0..reps]);
    last.factor_ms = median(times[reps .. 2 * reps]);
    last.solve_ms = median(times[2 * reps ..]);
    const Ctx = struct {
        st: solver.Stats,
        fn emit(c: @This(), w: *std.Io.Writer) !void {
            try report.writeStats(w, c.st);
            try w.writeByte('\n');
        }
    };
    try withOutput(null, Ctx{ .st = last });
    return 0;
}
