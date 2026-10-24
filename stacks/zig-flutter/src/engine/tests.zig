const std = @import("std");
const e = @import("engine.zig");

const cantilever =
    \\{"materials":[{"id":"steel","E":200e9}],"sections":[{"id":"BM","A":0.01,"I":8e-5}],
    \\"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
    \\"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
    \\"members":[{"id":1,"i":1,"j":2,"material":"steel","section":"BM"}],
    \\"load_cases":[{"id":"D","nodal":[{"node":2,"fx":0,"fy":-10000,"mz":0}],"member_udl":[]}]}
;

test "F01 cantilever tip load" {
    const gpa = std.testing.allocator;
    var diag: e.Diag = .{};
    var m = try e.model_json.parse(gpa, cantilever, &diag);
    defer m.deinit();
    var s = e.Solver.init(gpa);
    defer s.deinit();
    try s.solve(&m, m.sections, 1, &diag);
    const c = s.cases[0];
    try std.testing.expectApproxEqRel(-0.02604166667, c.disp[4], 1e-9);
    try std.testing.expectApproxEqRel(-0.0078125, c.disp[5], 1e-9);
    try std.testing.expectApproxEqRel(10000.0, c.reactions[1], 1e-9);
    try std.testing.expectApproxEqRel(50000.0, c.reactions[2], 1e-9);
    try std.testing.expect(c.residual < 1e-12);
}

test "unstable without supports" {
    const gpa = std.testing.allocator;
    var diag: e.Diag = .{};
    const text = std.mem.replaceOwned(u8, gpa, cantilever, "\"supports\":[{\"node\":1,\"ux\":true,\"uy\":true,\"rz\":true}]", "\"supports\":[]") catch unreachable;
    defer gpa.free(text);
    var m = try e.model_json.parse(gpa, text, &diag);
    defer m.deinit();
    var s = e.Solver.init(gpa);
    defer s.deinit();
    try std.testing.expectError(error.Model, s.solve(&m, m.sections, 1, &diag));
    try std.testing.expectEqual(e.model.ErrCode.unstable, diag.code);
}

test "gen 10x10 profile and dofs match the reference" {
    const gpa = std.testing.allocator;
    var m = try e.gen.generate(gpa, 10, 10);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 121), m.nodes.len);
    try std.testing.expectEqual(@as(usize, 210), m.members.len);
    var diag: e.Diag = .{};
    var s = e.Solver.init(gpa);
    defer s.deinit();
    try s.solve(&m, m.sections, 7, &diag);
    try std.testing.expectEqual(@as(u32, 330), s.stats.free_dofs);
    try std.testing.expectEqual(@as(u64, 10221), s.stats.profile_before);
    try std.testing.expectEqual(@as(u64, 7575), s.stats.profile_after);
    for (s.cases) |c| try std.testing.expect(c.residual < 1e-8);
}

test "model JSON round trip" {
    const gpa = std.testing.allocator;
    var m = try e.gen.generate(gpa, 3, 2);
    defer m.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try e.model_json.writeModel(&aw.writer, &m);
    var diag: e.Diag = .{};
    var m2 = try e.model_json.parse(gpa, aw.written(), &diag);
    defer m2.deinit();
    try std.testing.expectEqual(m.members.len, m2.members.len);
    try std.testing.expectEqual(m.nodes[5].x, m2.nodes[5].x);
}
