//! Member table: a virtualized, sortable teak.DataTable over the current results.
const std = @import("std");
const teak = @import("teak");
const state = @import("state.zig");
const engine = @import("engine.zig");

pub const Table = teak.DataTable(.{ .max_rows = 131_072, .max_cols = 8 });

pub const columns = [_]teak.DataTableColumn{
    .{ .title = "ID", .width = 64, .cell_align = .right },
    .{ .title = "i", .width = 56, .cell_align = .right },
    .{ .title = "j", .width = 56, .cell_align = .right },
    .{ .title = "L m", .width = 64, .cell_align = .right },
    .{ .title = "N_i kN", .width = 80, .cell_align = .right },
    .{ .title = "V_i kN", .width = 80, .cell_align = .right },
    .{ .title = "max|M| kNm", .width = 100, .cell_align = .right },
    .{ .title = "Rel", .width = 44, .cell_align = .center },
};

/// P2 end releases as a sortable code: 0 none, 1 i, 2 j, 3 both.
fn releaseCode(mb: anytype) f64 {
    const r = mb.release orelse return 0;
    const i: f64 = if (engine.model.hasMz(r.i)) 1 else 0;
    const j: f64 = if (engine.model.hasMz(r.j)) 2 else 0;
    return i + j;
}

/// Row source: data row = member position in id order.
pub const Rows = struct {
    m: *const state.Model,

    fn value(self: Rows, col: u8, row: u32) f64 {
        const m = self.m;
        const r = m.res orelse return 0;
        const mb = m.m.members[r.member_src[row]];
        const cr = m.caseResult() orelse return 0;
        return switch (col) {
            0 => @floatFromInt(mb.id),
            1 => @floatFromInt(mb.i),
            2 => @floatFromInt(mb.j),
            3 => cr.stations[row][cr.stations[row].len - 1].x,
            4 => cr.end_forces[row][0] / 1000,
            5 => cr.end_forces[row][1] / 1000,
            7 => releaseCode(mb),
            else => blk: {
                var mx: f64 = 0;
                for (cr.stations[row]) |s| mx = @max(mx, @abs(s.M));
                break :blk mx / 1000;
            },
        };
    }

    pub fn cell(self: Rows, arena: std.mem.Allocator, col: u8, row: u32) []const u8 {
        const v = self.value(col, row);
        return switch (col) {
            0, 1, 2 => std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(v))}) catch "?",
            3 => std.fmt.allocPrint(arena, "{d:.3}", .{v}) catch "?",
            7 => ([_][]const u8{ "-", "i", "j", "i+j" })[@intFromFloat(v)],
            else => std.fmt.allocPrint(arena, "{d:.2}", .{v}) catch "?",
        };
    }

    pub fn compare(self: Rows, col: u8, a: u32, b: u32) std.math.Order {
        return std.math.order(self.value(col, a), self.value(col, b));
    }
};

pub const msgs = struct {
    pub fn sort(col: u8) state.Msg {
        return .{ .table = .{ .sort = col } };
    }
    pub fn row(display: u32) state.Msg {
        return .{ .table = .{ .row = display } };
    }
};

pub fn view(m: *const state.Model, cb: anytype) void {
    Table.view(m.tbl, cb, &columns, Rows{ .m = m }, msgs, .{ .id = state.TABLE_ID, .grip_base = state.GRIP_BASE, .height = m.canvas_h - 30 });
}
