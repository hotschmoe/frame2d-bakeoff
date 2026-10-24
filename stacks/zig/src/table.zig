//! Virtualized, sortable member table (dvui GridWidget; only the visible rows are built each frame).
const std = @import("std");
const dvui = @import("dvui");
const engine = @import("engine");
const solver = engine.solver;
const state = @import("state.zig");
const App = state.App;

const cols = [_]struct { name: []const u8, key: state.SortCol }{
    .{ .name = "Member", .key = .id },
    .{ .name = "i", .key = .i },
    .{ .name = "j", .key = .j },
    .{ .name = "L (m)", .key = .length },
    .{ .name = "N_i", .key = .n_i },
    .{ .name = "V_i", .key = .v_i },
    .{ .name = "M_i", .key = .m_i },
    .{ .name = "max |M|", .key = .max_m },
};

pub fn show(app: *App) void {
    const n = app.model.members.len;
    var grid = dvui.grid(@src(), .{ .scroll_opts = .{ .horizontal = .auto }, .rows = n }, .{ .expand = .both, .min_size_content = .{ .w = 360, .h = 100 } });
    defer grid.deinit();

    for (cols, 0..) |c, ci| {
        const cell = grid.colHeader(.{ .col = ci }, .{ .border = .all(1) });
        defer cell.deinit();
        if (cell.headerSortable(c.name, .{})) |dir| {
            app.sortBy(c.key, dir != .descending);
        }
    }

    const order = app.ensureOrder();
    if (order.len != n) return;
    const cr = app.caseResult();
    const res = if (app.results) |*r| r else null;
    const start, const end = grid.rowsVisible();
    for (start..@min(end, n)) |row| {
        const k = order[row];
        const m = app.model.members[k];
        inline for (0..cols.len) |ci| {
            var cell = grid.cell(.{ .col = ci, .row = row }, .{});
            defer cell.deinit();
            switch (ci) {
                0 => dvui.label(@src(), "{d}", .{m.id}, .{}),
                1 => dvui.label(@src(), "{d}", .{m.i}, .{}),
                2 => dvui.label(@src(), "{d}", .{m.j}, .{}),
                3 => if (res) |r| dvui.label(@src(), "{d:.2}", .{r.length[k]}, .{}),
                4 => if (cr) |c| dvui.label(@src(), "{d:.0}", .{c.end_forces[k * 6]}, .{}),
                5 => if (cr) |c| dvui.label(@src(), "{d:.0}", .{c.end_forces[k * 6 + 1]}, .{}),
                6 => if (cr) |c| dvui.label(@src(), "{d:.0}", .{c.end_forces[k * 6 + 2]}, .{}),
                else => if (k < app.member_max_m.len) dvui.label(@src(), "{d:.0}", .{app.member_max_m[k]}, .{}),
            }
        }
    }
}
