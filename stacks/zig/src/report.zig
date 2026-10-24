//! JSON writers for results (SPEC 5.2) and model errors (SPEC 4.6).
const std = @import("std");
const solver = @import("solver.zig");
const model_mod = @import("model.zig");
const Writer = std.Io.Writer;

fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn optU64(w: *Writer, v: ?u64) Writer.Error!void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

pub fn writeError(w: *Writer, info: *const solver.ErrorInfo) Writer.Error!void {
    try w.print("{{\"error\":\"{s}\",\"detail\":", .{@tagName(info.code)});
    try str(w, info.detail());
    try w.writeAll("}\n");
}

pub fn writeStats(w: *Writer, s: solver.Stats) Writer.Error!void {
    try w.print("{{\"nodes\":{d},\"members\":{d},\"free_dofs\":{d},\"profile_before\":{d},\"profile_after\":{d}," ++
        "\"assemble_ms\":{d:.3},\"factor_ms\":{d:.3},\"solve_ms\":{d:.3},\"alloc_count\":", .{
        s.nodes,          s.members,     s.free_dofs,   s.profile_before, s.profile_after,
        s.assemble_ms,    s.factor_ms,   s.solve_ms,
    });
    try optU64(w, s.alloc_count);
    try w.writeAll(",\"alloc_bytes\":");
    try optU64(w, s.alloc_bytes);
    try w.writeAll(",\"peak_heap_bytes\":");
    try optU64(w, s.peak_heap_bytes);
    try w.writeByte('}');
}

pub fn writeResults(w: *Writer, m: *const model_mod.Model, res: *const solver.Results) Writer.Error!void {
    try w.writeAll("{\"load_cases\":[");
    for (res.cases, 0..) |c, ci| {
        if (ci > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try str(w, c.id);
        try w.writeAll(",\"displacements\":[");
        for (m.nodes, 0..) |n, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"ux\":{},\"uy\":{},\"rz\":{}}}", .{ n.id, c.u[k * 3], c.u[k * 3 + 1], c.u[k * 3 + 2] });
        }
        try w.writeAll("],\"reactions\":[");
        for (c.reactions, 0..) |r, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"fx\":{},\"fy\":{},\"mz\":{}}}", .{ m.nodes[r.node].id, r.f[0], r.f[1], r.f[2] });
        }
        try w.writeAll("],\"members\":[");
        for (m.members, 0..) |mem, k| {
            if (k > 0) try w.writeByte(',');
            const ef = c.end_forces[k * 6 ..][0..6];
            try w.print("{{\"id\":{d},\"end_forces\":[{},{},{},{},{},{}],\"stations\":[", .{ mem.id, ef[0], ef[1], ef[2], ef[3], ef[4], ef[5] });
            for (0..solver.stations) |q| {
                const st = solver.station(ef, c.w[k], res.length[k], q);
                if (q > 0) try w.writeByte(',');
                try w.print("{{\"x\":{},\"N\":{},\"V\":{},\"M\":{}}}", .{ st.x, st.N, st.V, st.M });
            }
            try w.writeAll("]}");
        }
        try w.print("],\"equilibrium_residual\":{}}}", .{c.residual});
    }
    try w.writeAll("],\"warnings\":[],\"stats\":");
    try writeStats(w, res.stats);
    try w.writeAll("}\n");
}
