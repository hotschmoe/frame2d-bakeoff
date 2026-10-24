//! Results JSON writer (SPEC 5.2) and the error body.
const std = @import("std");
const model = @import("model.zig");
const solver = @import("solver.zig");
const writeNum = @import("model_json.zig").writeNum;

pub const AllocStats = struct { count: u64, bytes: u64, peak: u64 };

pub fn writeError(w: *std.Io.Writer, d: *const model.Diag) std.Io.Writer.Error!void {
    try w.print("{{\"error\":\"{s}\",\"detail\":\"", .{@tagName(d.code)});
    for (d.detail()) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
    try w.writeAll("\"}");
}

pub fn writeResults(
    w: *std.Io.Writer,
    m: *const model.Model,
    s: *const solver.Solver,
    alloc_stats: ?AllocStats,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"load_cases\":[");
    var first_case = true;
    for (m.load_cases, s.cases) |lc, c| {
        if (!c.solved) continue;
        if (!first_case) try w.writeByte(',');
        first_case = false;
        try w.print("{{\"id\":\"{s}\",\"displacements\":[", .{lc.id});
        for (m.nodes, 0..) |n, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"ux\":", .{n.id});
            try writeNum(w, c.disp[k * 3]);
            try w.writeAll(",\"uy\":");
            try writeNum(w, c.disp[k * 3 + 1]);
            try w.writeAll(",\"rz\":");
            try writeNum(w, c.disp[k * 3 + 2]);
            try w.writeByte('}');
        }
        try w.writeAll("],\"reactions\":[");
        var first = true;
        for (m.nodes, 0..) |n, k| {
            if (m.restraint[k] == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"node\":{d},\"fx\":", .{n.id});
            try writeNum(w, c.reactions[k * 3]);
            try w.writeAll(",\"fy\":");
            try writeNum(w, c.reactions[k * 3 + 1]);
            try w.writeAll(",\"mz\":");
            try writeNum(w, c.reactions[k * 3 + 2]);
            try w.writeByte('}');
        }
        try w.writeAll("],\"members\":[");
        for (m.members, 0..) |mem, k| {
            if (k > 0) try w.writeByte(',');
            const ef = c.end_forces[k * 6 ..][0..6];
            try w.print("{{\"id\":{d},\"end_forces\":[", .{mem.id});
            for (ef, 0..) |v, q| {
                if (q > 0) try w.writeByte(',');
                try writeNum(w, v);
            }
            try w.writeAll("],\"stations\":[");
            const L = m.memberLength(k);
            for (0..solver.station_count) |q| {
                const st = solver.station(L, c.w[k], ef, q);
                if (q > 0) try w.writeByte(',');
                try w.writeAll("{\"x\":");
                try writeNum(w, st.x);
                try w.writeAll(",\"N\":");
                try writeNum(w, st.N);
                try w.writeAll(",\"V\":");
                try writeNum(w, st.V);
                try w.writeAll(",\"M\":");
                try writeNum(w, st.M);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("],\"equilibrium_residual\":");
        try writeNum(w, c.residual);
        try w.writeByte('}');
    }
    const st = s.stats;
    try w.writeAll("],\"warnings\":[");
    if (s.plan) |p| for (p.auto, 0..) |nd, q| {
        if (q > 0) try w.writeByte(',');
        try w.print("{{\"warning\":\"auto_restrained\",\"node\":{d},\"dof\":\"rz\"}}", .{m.nodes[nd].id});
    };
    try w.print("],\"stats\":{{\"nodes\":{d},\"members\":{d},\"free_dofs\":{d},\"profile_before\":{d},\"profile_after\":{d},\"assemble_ms\":", .{
        st.nodes, st.members, st.free_dofs, st.profile_before, st.profile_after,
    });
    try writeNum(w, st.assemble_ms);
    try w.writeAll(",\"factor_ms\":");
    try writeNum(w, st.factor_ms);
    try w.writeAll(",\"solve_ms\":");
    try writeNum(w, st.solve_ms);
    if (alloc_stats) |a| {
        try w.print(",\"alloc_count\":{d},\"alloc_bytes\":{d},\"peak_heap_bytes\":{d}", .{ a.count, a.bytes, a.peak });
    } else {
        try w.writeAll(",\"alloc_count\":null,\"alloc_bytes\":null,\"peak_heap_bytes\":null");
    }
    try w.writeAll("}}");
}
