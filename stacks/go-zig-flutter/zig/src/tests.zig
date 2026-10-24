//! Unit tests (run with `zig test src/tests.zig`; see test_all in stack.sh).
const std = @import("std");
const testing = std.testing;
const engine = @import("engine.zig");
const model = @import("model.zig");
const results = @import("results.zig");
const session = @import("session.zig");
const util = @import("util.zig");
const json = @import("json.zig");

const gpa = testing.allocator;

const cantilever =
    \\{"materials":[{"id":"s","E":200e9}],"sections":[{"id":"b","A":0.01,"I":8e-5}],
    \\ "nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
    \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],
    \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],
    \\ "load_cases":[{"id":"P","nodal":[{"node":2,"fy":-10000}],"member_udl":[]}]}
;

fn solveText(a: std.mem.Allocator, text: []const u8, d: *model.Diag) model.Error!struct { p: *engine.Prepared, outs: []engine.CaseOut } {
    const m = try model.parseModel(a, text, d);
    const p = try engine.prepare(gpa, &m, d);
    errdefer p.deinit();
    const outs = try a.alloc(engine.CaseOut, p.cases.len);
    for (outs) |*o| o.* = try engine.CaseOut.alloc(a, p);
    var st: engine.Stats = undefined;
    try engine.solve(p, null, outs, &st, d);
    return .{ .p = p, .outs = outs };
}

test "cantilever tip load (F01)" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    const r = try solveText(ar.allocator(), cantilever, &d);
    defer r.p.deinit();
    const u = r.outs[0].u;
    try testing.expectApproxEqAbs(-0.026041666666666668, u[4], 1e-12);
    try testing.expectApproxEqAbs(-0.0078125, u[5], 1e-12);
    try testing.expectApproxEqAbs(10000.0, r.outs[0].react[1], 1e-6);
    try testing.expectApproxEqAbs(50000.0, r.outs[0].react[2], 1e-6);
}

test "gen 10x10 profiles match the reference" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var d = model.Diag{};
    const m = try model.gen(a, 10, 10);
    const p = try engine.prepare(gpa, &m, &d);
    defer p.deinit();
    const outs = try a.alloc(engine.CaseOut, 3);
    for (outs) |*o| o.* = try engine.CaseOut.alloc(a, p);
    var st: engine.Stats = undefined;
    try engine.solve(p, null, outs, &st, &d);
    try testing.expectEqual(@as(usize, 330), st.free_dofs);
    try testing.expectEqual(@as(usize, 10221), st.profile_before);
    try testing.expectEqual(@as(usize, 7575), st.profile_after);
    for (outs) |o| try testing.expect(o.residual < 1e-8);
}

fn expectCode(text: []const u8, code: model.Code) !void {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var d = model.Diag{};
    if (solveText(ar.allocator(), text, &d)) |r| {
        r.p.deinit();
        return error.TestExpectedError;
    } else |_| {}
    try testing.expectEqual(code, d.code);
}

test "model errors" {
    // no supports -> unstable
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":5,"y":0}],
        \\ "members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[{"id":"P"}]}
    , .unstable);
    // missing node
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0}],
        \\ "supports":[{"node":1,"ux":true}],"members":[{"id":1,"i":1,"j":99,"material":"s","section":"b"}],"load_cases":[]}
    , .invalid_ref);
    // zero length
    try expectCode(
        \\{"materials":[{"id":"s","E":2e11}],"sections":[{"id":"b","A":0.01,"I":8e-5}],"nodes":[{"id":1,"x":0,"y":0},{"id":2,"x":0,"y":0}],
        \\ "supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[{"id":1,"i":1,"j":2,"material":"s","section":"b"}],"load_cases":[]}
    , .zero_length);
    // duplicate node
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0},{"id":1,"x":1,"y":0}],"members":[],"load_cases":[]}
    , .duplicate_id);
    // every DOF restrained
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"ux":true,"uy":true,"rz":true}],"members":[],"load_cases":[]}
    , .no_free_dofs);
    // restrained and sprung
    try expectCode(
        \\{"materials":[],"sections":[],"nodes":[{"id":1,"x":0,"y":0}],"supports":[{"node":1,"uy":true}],"springs":[{"node":1,"ky":5}],"members":[],"load_cases":[]}
    , .support_conflict);
    // malformed JSON
    try expectCode("{\"nodes\":[", .bad_request);
}

test "sweep endpoints: stiffer beams reduce drift" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var d = model.Diag{};
    const m = try model.gen(a, 3, 3);
    var b = util.Buf{ .a = a };
    try model.writeModel(&b, &m);
    const base = try results.sweepOpen(gpa, b.slice(), &d);
    defer results.sweepClose(base);
    const w = try results.sweepWorkerNew(gpa, base);
    defer results.sweepWorkerFree(w);
    const soft = try results.sweepRun(w, 0.5, &d);
    const stiff = try results.sweepRun(w, 2.0, &d);
    try testing.expect(soft.drift > stiff.drift);
    try testing.expect(soft.max_m > 0);
}

test "session: gen, solve, move a node" {
    var d = model.Diag{};
    var ar = std.heap.ArenaAllocator.init(gpa);
    const m = try model.gen(ar.allocator(), 2, 2);
    const s = try session.create(ar, m, &d);
    defer session.destroy(s);
    try testing.expectEqual([3]i32{ 9, 10, 3 }, s.counts());
    try s.solve(0, &d);
    try testing.expectEqual(@as(f64, 18), s.stats[0]);
    try testing.expect(s.stats[6] < 1e-8);
    const base = try gpa.dupe(f64, s.res);
    defer gpa.free(base);
    s.setNode(8, 12.5, 7.5);
    try s.solve(0, &d);
    var changed = false;
    for (base, s.res) |x, y| if (@abs(x - y) > 1e-12) {
        changed = true;
    };
    try testing.expect(changed);
    const out = try s.toJson();
    try testing.expect(std.mem.indexOf(u8, out, "12.5") != null or std.mem.indexOf(u8, out, "1.25e1") != null);
}

test "json numbers round trip" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    var b = util.Buf{ .a = ar.allocator() };
    const vals = [_]f64{ 0, -0.0, 1, 0.1, 1.0 / 3.0, 1e-300, 1.7976931348623157e308, -2.5e-9, 123456.789 };
    for (vals) |v| {
        b.list.len = 0;
        try b.num(v);
        const back = try std.fmt.parseFloat(f64, b.slice());
        try testing.expectEqual(v, back);
    }
    const v = try json.parse(ar.allocator(), "{\"a\":[1,2,{\"b\":\"x\\u0041\\n\"}],\"c\":null}");
    try testing.expectEqualStrings("xA\n", v.get("a").?.arr[2].get("b").?.str);
}
