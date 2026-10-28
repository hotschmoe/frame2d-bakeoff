//! Results / error JSON (SPEC 5.2, 4.6).
const std = @import("std");
const engine = @import("engine.zig");
const model = engine.model;
const writeNum = model.writeNum;

pub fn writeError(w: *std.Io.Writer, e: engine.ModelError) !void {
    try w.writeAll("{\"error\":");
    try model.writeStr(w, e.code);
    try w.writeAll(",\"detail\":");
    try model.writeStr(w, e.detail);
    try w.writeAll("}\n");
}

fn optInt(w: *std.Io.Writer, v: ?u64) !void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

pub fn writeResults(w: *std.Io.Writer, m: model.Model, r: engine.Results) !void {
    try w.writeAll("{\"load_cases\":[");
    for (r.cases, 0..) |c, ci| {
        if (ci > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try model.writeStr(w, c.id);
        try w.writeAll(",\n\"displacements\":[");
        for (c.disp, 0..) |d, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"node\":{d},\"ux\":", .{m.nodes[r.node_src[k]].id});
            try writeNum(w, d[0]);
            try w.writeAll(",\"uy\":");
            try writeNum(w, d[1]);
            try w.writeAll(",\"rz\":");
            try writeNum(w, d[2]);
            try w.writeByte('}');
        }
        try w.writeAll("],\n\"reactions\":[");
        var first = true;
        for (c.react, 0..) |rv, k| {
            if (!r.supported[k]) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"node\":{d},\"fx\":", .{m.nodes[r.node_src[k]].id});
            try writeNum(w, rv[0]);
            try w.writeAll(",\"fy\":");
            try writeNum(w, rv[1]);
            try w.writeAll(",\"mz\":");
            try writeNum(w, rv[2]);
            try w.writeByte('}');
        }
        try w.writeAll("],\n\"members\":[");
        for (c.end_forces, 0..) |f, k| {
            if (k > 0) try w.writeAll(",\n");
            try w.print("{{\"id\":{d},\"end_forces\":[", .{m.members[r.member_src[k]].id});
            for (f, 0..) |v, q| {
                if (q > 0) try w.writeByte(',');
                try writeNum(w, v);
            }
            try w.writeAll("],\"stations\":[");
            for (c.stations[k], 0..) |s, q| {
                if (q > 0) try w.writeByte(',');
                try w.writeAll("{\"x\":");
                try writeNum(w, s.x);
                try w.writeAll(",\"N\":");
                try writeNum(w, s.N);
                try w.writeAll(",\"V\":");
                try writeNum(w, s.V);
                try w.writeAll(",\"M\":");
                try writeNum(w, s.M);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("],\n\"equilibrium_residual\":");
        try writeNum(w, c.residual);
        try w.writeByte('}');
    }
    try w.writeAll("],\n\"warnings\":[");
    for (r.auto_restrained, 0..) |pos, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{{\"warning\":\"auto_restrained\",\"node\":{d},\"dof\":\"rz\"}}", .{m.nodes[r.node_src[pos]].id});
    }
    try w.writeAll("],\n\"stats\":");
    try writeStats(w, r.stats);
    try w.writeAll("}\n");
}

pub fn writeStats(w: *std.Io.Writer, s: engine.Stats) !void {
    try w.print("{{\"nodes\":{d},\"members\":{d},\"free_dofs\":{d},\"profile_before\":{d},\"profile_after\":{d},\"assemble_ms\":", .{ s.nodes, s.members, s.free_dofs, s.profile_before, s.profile_after });
    try writeNum(w, s.assemble_ms);
    try w.writeAll(",\"factor_ms\":");
    try writeNum(w, s.factor_ms);
    try w.writeAll(",\"solve_ms\":");
    try writeNum(w, s.solve_ms);
    try w.writeAll(",\"alloc_count\":");
    try optInt(w, s.alloc_count);
    try w.writeAll(",\"alloc_bytes\":");
    try optInt(w, s.alloc_bytes);
    try w.writeAll(",\"peak_heap_bytes\":");
    try optInt(w, s.peak_heap_bytes);
    try w.writeByte('}');
}
