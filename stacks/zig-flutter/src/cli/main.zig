//! frame2d CLI (SPEC 5.3): solve / gen / bench. Exit 0 ok, 2 model error (JSON on stdout), 1 anything else.
const std = @import("std");
const engine = @import("engine");

const usage =
    \\usage: frame2d solve <model.json> [-o results.json]
    \\       frame2d gen <B> <S> [-o model.json]
    \\       frame2d bench <B> <S> [--reps N]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(io, usage);
        return 1;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "solve")) return cmdSolve(io, gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "gen")) return cmdGen(io, gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "bench")) return cmdBench(io, gpa, args[2..]);
    try std.Io.File.stderr().writeStreamingAll(io, usage);
    return 1;
}

fn outputPath(args: []const [:0]const u8) ?[]const u8 {
    for (args, 0..) |a, k| {
        if (std.mem.eql(u8, a, "-o") and k + 1 < args.len) return args[k + 1];
    }
    return null;
}

fn emit(io: std.Io, path: ?[]const u8, bytes: []const u8) !void {
    if (path) |p| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
    }
}

fn modelError(io: std.Io, gpa: std.mem.Allocator, diag: *const engine.Diag) !u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try engine.results_json.writeError(&aw.writer, diag);
    try aw.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, aw.written());
    return 2;
}

fn cmdSolve(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len < 1) return 1;
    const text = std.Io.Dir.cwd().readFileAlloc(io, args[0], gpa, .limited(1 << 30)) catch |e| {
        std.debug.print("cannot read {s}: {t}\n", .{ args[0], e });
        return 1;
    };
    defer gpa.free(text);
    var diag: engine.Diag = .{};
    var m = engine.model_json.parse(gpa, text, &diag) catch |e| switch (e) {
        error.Model => return modelError(io, gpa, &diag),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer m.deinit();

    var counting = engine.CountingAllocator.init(gpa);
    var s = engine.Solver.init(counting.allocator());
    defer s.deinit();
    s.solve(&m, m.sections, std.math.maxInt(u32), &diag) catch |e| switch (e) {
        error.Model => return modelError(io, gpa, &diag),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const alloc_stats: engine.results_json.AllocStats = .{
        .count = counting.count.load(.monotonic),
        .bytes = counting.bytes.load(.monotonic),
        .peak = counting.peak.load(.monotonic),
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try engine.results_json.writeResults(&aw.writer, &m, &s, alloc_stats);
    try aw.writer.writeByte('\n');
    try emit(io, outputPath(args[1..]), aw.written());
    return 0;
}

fn parseDim(args: []const [:0]const u8) ?struct { b: u32, s: u32 } {
    if (args.len < 2) return null;
    const b = std.fmt.parseInt(u32, args[0], 10) catch return null;
    const s = std.fmt.parseInt(u32, args[1], 10) catch return null;
    return .{ .b = b, .s = s };
}

fn cmdGen(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    const dim = parseDim(args) orelse return 1;
    var m = try engine.gen.generate(gpa, dim.b, dim.s);
    defer m.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try engine.model_json.writeModel(&aw.writer, &m);
    try aw.writer.writeByte('\n');
    try emit(io, outputPath(args[2..]), aw.written());
    return 0;
}

fn median(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    return vals[vals.len / 2];
}

fn cmdBench(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    const dim = parseDim(args) orelse return 1;
    var reps: usize = 1;
    for (args, 0..) |a, k| {
        if (std.mem.eql(u8, a, "--reps") and k + 1 < args.len) reps = std.fmt.parseInt(usize, args[k + 1], 10) catch return 1;
    }
    if (reps == 0) return 1;
    var m = try engine.gen.generate(gpa, dim.b, dim.s);
    defer m.deinit();
    const asm_ms = try gpa.alloc(f64, reps);
    defer gpa.free(asm_ms);
    const fac_ms = try gpa.alloc(f64, reps);
    defer gpa.free(fac_ms);
    const sol_ms = try gpa.alloc(f64, reps);
    defer gpa.free(sol_ms);
    var last: engine.solver.Stats = .{};
    var alloc_stats: engine.results_json.AllocStats = .{ .count = 0, .bytes = 0, .peak = 0 };
    var diag: engine.Diag = .{};
    for (0..reps) |r| {
        var counting = engine.CountingAllocator.init(gpa);
        var s = engine.Solver.init(counting.allocator());
        defer s.deinit();
        s.solve(&m, m.sections, std.math.maxInt(u32), &diag) catch |e| switch (e) {
            error.Model => return modelError(io, gpa, &diag),
            error.OutOfMemory => return error.OutOfMemory,
        };
        last = s.stats;
        asm_ms[r] = s.stats.assemble_ms;
        fac_ms[r] = s.stats.factor_ms;
        sol_ms[r] = s.stats.solve_ms;
        alloc_stats = .{
            .count = counting.count.load(.monotonic),
            .bytes = counting.bytes.load(.monotonic),
            .peak = counting.peak.load(.monotonic),
        };
    }
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"nodes\":{d},\"members\":{d},\"free_dofs\":{d},\"profile_before\":{d},\"profile_after\":{d},\"reps\":{d}", .{
        last.nodes, last.members, last.free_dofs, last.profile_before, last.profile_after, reps,
    });
    try w.print(",\"assemble_ms\":{d:.3},\"factor_ms\":{d:.3},\"solve_ms\":{d:.3}", .{ median(asm_ms), median(fac_ms), median(sol_ms) });
    try w.print(",\"alloc_count\":{d},\"alloc_bytes\":{d},\"peak_heap_bytes\":{d}}}\n", .{ alloc_stats.count, alloc_stats.bytes, alloc_stats.peak });
    try std.Io.File.stdout().writeStreamingAll(io, aw.written());
    return 0;
}
