//! Engine tests beyond the cantilever smoke tests in engine.zig: P2 springs and releases,
//! skyline factor/solve, and the JSON report writer.
const std = @import("std");
const model = @import("model.zig");
const solver = @import("solver.zig");
const report = @import("report.zig");

const head =
    \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
    \\"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
;

fn solveText(arena: std.mem.Allocator, text: []const u8, m: *model.Model) !solver.Results {
    m.* = try model.parse(arena, text);
    var info: solver.ErrorInfo = .{};
    return solver.solve(std.testing.allocator, m, &info);
}

test "tip spring halves the cantilever deflection (F21)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: model.Model = undefined;
    var res = try solveText(arena.allocator(), head ++
        \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
        \\"springs":[{"node":2,"ky":384000}],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
        \\"load_cases":[{"id":"D","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
    , &m);
    defer res.deinit();
    try std.testing.expectApproxEqRel(-0.013020833333, res.cases[0].u[4], 1e-9);
}

test "mz release at the free end gives zero end moment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: model.Model = undefined;
    // Propped cantilever under UDL: fixed at 1, roller (uy) at 2 with a moment release there.
    var res = try solveText(arena.allocator(), head ++
        \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true},{"node":2,"uy":true}],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b","release":{"j":["mz"]}}],
        \\"load_cases":[{"id":"D","nodal":[],"member_udl":[{"member":1,"w":-1000}]}]}
    , &m);
    defer res.deinit();
    const ef = res.cases[0].end_forces;
    try std.testing.expectApproxEqAbs(0.0, ef[5], 1e-6);
    try std.testing.expectApproxEqRel(1000.0 * 25.0 / 8.0, @abs(ef[2]), 1e-9);
}

test "fully released node is auto-restrained with a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: model.Model = undefined;
    // Node 2 has pins on both members and no rotational spring: its rz has no stiffness.
    var res = try solveText(arena.allocator(),
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
        \\"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0},{"id":3,"x":10,"y":0}],
        \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true},{"node":2,"ux":true,"uy":true},{"node":3,"ux":true,"uy":true}],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b","release":{"j":["mz"]}},
        \\{"id":2,"i":2,"j":3,"material":"s","section":"b","release":{"i":["mz"]}}],
        \\"load_cases":[{"id":"D","nodal":[{"node":3,"mz":1000}],"member_udl":[]}]}
    , &m);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.warnings.len);
    try std.testing.expectEqual(@as(u32, 1), res.warnings[0]);
}

test "skyline LDL^T solves a small SPD system" {
    // A = [[4,1,0],[1,3,1],[0,1,2]], columns stored top to bottom with the diagonal last.
    var colptr = [_]usize{ 0, 1, 3, 5 };
    var a = [_]f64{ 4, 1, 3, 1, 2 };
    var sk = solver.Skyline{ .n = 3, .colptr = &colptr, .a = &a };
    try std.testing.expectEqual(@as(?usize, null), solver.factor(&sk, 4));
    var b = [_]f64{ 1, 2, 3 };
    solver.solveInPlace(&sk, &b);
    try std.testing.expectApproxEqAbs(4 * b[0] + b[1], 1, 1e-12);
    try std.testing.expectApproxEqAbs(b[0] + 3 * b[1] + b[2], 2, 1e-12);
    try std.testing.expectApproxEqAbs(b[1] + 2 * b[2], 3, 1e-12);
}

test "skyline factor reports a singular pivot" {
    var colptr = [_]usize{ 0, 1, 3 };
    var a = [_]f64{ 1, 1, 1 }; // [[1,1],[1,1]]
    var sk = solver.Skyline{ .n = 2, .colptr = &colptr, .a = &a };
    try std.testing.expectEqual(@as(?usize, 1), solver.factor(&sk, 1));
}

test "results JSON is valid and repeats cached numbers faithfully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m: model.Model = undefined;
    var res = try solveText(arena.allocator(), head ++
        \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
        \\"load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
    , &m);
    defer res.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try report.writeResults(&out.writer, &m, &res);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const stations = parsed.value.object.get("load_cases").?.array.items[0].object.get("members").?.array.items[0].object.get("stations").?.array;
    try std.testing.expectEqual(@as(usize, solver.stations), stations.items.len);
    const ef = res.cases[0].end_forces;
    for (stations.items, 0..) |s, q| {
        const st = solver.station(ef[0..6], res.cases[0].w[0], res.length[0], q);
        try std.testing.expectEqual(st.V, switch (s.object.get("V").?) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TestUnexpectedResult,
        });
    }
}
