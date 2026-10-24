//! Engine root: model types, solver, JSON writers. No OS dependencies.
const std = @import("std");
pub const model = @import("model.zig");
pub const solver = @import("solver.zig");
pub const report = @import("report.zig");
pub const Counting = @import("counting.zig");

test {
    _ = model;
    _ = solver;
}

test "cantilever tip deflection (F01)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text =
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
        \\"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
        \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
        \\"load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
    ;
    var m = try model.parse(arena.allocator(), text);
    var info: solver.ErrorInfo = .{};
    var res = try solver.solve(gpa, &m, &info);
    defer res.deinit();
    try std.testing.expectApproxEqRel(-0.02604166667, res.cases[0].u[4], 1e-9);
}

test "unsupported beam is unstable" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text =
        \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
        \\"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],"supports":[],
        \\"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[]}
    ;
    var m = try model.parse(arena.allocator(), text);
    var info: solver.ErrorInfo = .{};
    try std.testing.expectError(error.ModelError, solver.solve(gpa, &m, &info));
    try std.testing.expectEqual(solver.Code.unstable, info.code);
}
