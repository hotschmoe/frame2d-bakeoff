//! Client state: the current model, its results, view settings and the member table order.
const std = @import("std");
const engine = @import("engine");
const model_mod = engine.model;
const solver = engine.solver;
const platform = @import("platform.zig");

pub const Model = model_mod.Model;

pub const SortCol = enum { id, i, j, length, n_i, v_i, m_i, max_m };

pub const View = struct {
    /// world coordinates (m) at the canvas center
    cx: f64 = 0,
    cy: f64 = 0,
    /// pixels per metre (physical)
    scale: f64 = 1,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: Model = .{},
    results: ?solver.Results = null,
    /// results.cases[0] corresponds to load case `case_offset`
    case_offset: usize = 0,
    case: usize = 0,
    err_text: [200]u8 = undefined,
    err_len: usize = 0,
    status: [160]u8 = undefined,
    status_len: usize = 0,

    view: View = .{},
    fit_pending: bool = true,
    /// bumped whenever a new model is adopted
    epoch: u32 = 0,

    show_deflected: bool = true,
    show_moment: bool = false,
    color_by_moment: bool = true,
    /// slider fraction 0..1, magnification = auto * 10^(2f-1)
    defl_slider: f32 = 0.5,
    moment_slider: f32 = 0.5,

    selected_node: ?usize = null,
    hover_node: ?usize = null,
    dragging_node: bool = false,
    dirty: bool = false,

    gen_bays: f32 = 10,
    gen_stories: f32 = 10,
    show_gen: bool = false,

    // derived per results/case
    max_disp: f64 = 0,
    max_m_model: f64 = 0,
    member_max_m: []f32 = &.{},

    // member table
    sort_col: SortCol = .id,
    sort_asc: bool = true,
    order: []u32 = &.{},
    order_dirty: bool = true,

    last_solve_ms: f64 = 0,
    solve_count: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn errText(self: *const App) []const u8 {
        return self.err_text[0..self.err_len];
    }

    pub fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status, fmt, args) catch self.status[0..0];
        self.status_len = s.len;
    }

    fn setError(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.err_text, fmt, args) catch self.err_text[0..0];
        self.err_len = s.len;
    }

    fn clearResults(self: *App) void {
        if (self.results) |*r| r.deinit();
        self.results = null;
    }

    /// Replaces the model with one parsed from JSON text.
    pub fn loadJson(self: *App, text: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const m = model_mod.parse(arena.allocator(), text) catch |e| {
            arena.deinit();
            self.setError("cannot parse model: {s}", .{@errorName(e)});
            return;
        };
        self.adopt(arena, m);
    }

    pub fn generate(self: *App, bays: usize, stories: usize) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const m = model_mod.generate(arena.allocator(), bays, stories) catch {
            arena.deinit();
            self.setError("out of memory generating model", .{});
            return;
        };
        self.adopt(arena, m);
    }

    fn adopt(self: *App, arena: std.heap.ArenaAllocator, m: Model) void {
        self.clearResults();
        self.arena.deinit();
        self.arena = arena;
        self.model = m;
        self.epoch +%= 1;
        self.err_len = 0;
        self.selected_node = null;
        self.hover_node = null;
        self.case = 0;
        var info: solver.ErrorInfo = .{};
        solver.normalize(&self.model, &info) catch {
            self.setError("{s}: {s}", .{ @tagName(info.code), info.detail() });
            return;
        };
        self.fit_pending = true;
        self.resolve(null);
    }

    /// Solves the model (all load cases, or only `only`). Runs on the calling thread.
    pub fn resolve(self: *App, only: ?usize) void {
        self.clearResults();
        self.dirty = false;
        var m = self.model;
        var off: usize = 0;
        if (only) |k| {
            if (k < m.load_cases.len) {
                m.load_cases = m.load_cases[k .. k + 1];
                off = k;
            }
        }
        var info: solver.ErrorInfo = .{};
        const t0 = platform.nowMs();
        const res = solver.solve(self.gpa, &m, &info) catch |e| {
            if (e == error.ModelError) {
                self.setError("{s}: {s}", .{ @tagName(info.code), info.detail() });
            } else {
                self.setError("out of memory", .{});
            }
            return;
        };
        self.last_solve_ms = platform.nowMs() - t0;
        self.solve_count += 1;
        self.err_len = 0;
        self.results = res;
        self.case_offset = off;
        self.setStatus("{d} nodes, {d} members, {d} dof | solve {d:.1} ms", .{ res.stats.nodes, res.stats.members, res.stats.free_dofs, self.last_solve_ms });
        self.deriveCase();
    }

    /// The result for the selected load case, if it has been solved.
    pub fn caseResult(self: *const App) ?*const solver.CaseResult {
        const r = &(self.results orelse return null);
        if (self.case < self.case_offset or self.case - self.case_offset >= r.cases.len) return null;
        return &r.cases[self.case - self.case_offset];
    }

    /// Recomputes per-member max |M|, global maxima, after results or the load case changed.
    pub fn deriveCase(self: *App) void {
        self.order_dirty = true;
        const n = self.model.members.len;
        if (self.member_max_m.len != n) {
            self.gpa.free(self.member_max_m);
            self.member_max_m = self.gpa.alloc(f32, n) catch &.{};
        }
        self.max_disp = 0;
        self.max_m_model = 0;
        const cr = self.caseResult() orelse {
            @memset(self.member_max_m, 0);
            return;
        };
        const res = &self.results.?;
        for (0..n) |k| {
            if (k >= self.member_max_m.len) break;
            const mm = solver.maxAbsM(cr.end_forces[k * 6 ..][0..6], cr.w[k], res.length[k]);
            self.member_max_m[k] = @floatCast(mm);
            self.max_m_model = @max(self.max_m_model, mm);
        }
        for (0..self.model.nodes.len) |k| {
            self.max_disp = @max(self.max_disp, @max(@abs(cr.u[k * 3]), @abs(cr.u[k * 3 + 1])));
        }
    }

    pub fn setCase(self: *App, k: usize) void {
        if (k == self.case) return;
        self.case = k;
        if (self.caseResult() == null) self.resolve(null) else self.deriveCase();
    }

    // ---- member table ordering

    fn keyOf(self: *const App, k: u32) f64 {
        const m = self.model.members[k];
        const cr = self.caseResult();
        return switch (self.sort_col) {
            .id => @floatFromInt(m.id),
            .i => @floatFromInt(m.i),
            .j => @floatFromInt(m.j),
            .length => if (self.results) |r| r.length[k] else 0,
            .n_i => if (cr) |c| c.end_forces[k * 6] else 0,
            .v_i => if (cr) |c| c.end_forces[k * 6 + 1] else 0,
            .m_i => if (cr) |c| c.end_forces[k * 6 + 2] else 0,
            .max_m => if (k < self.member_max_m.len) self.member_max_m[k] else 0,
        };
    }

    fn lessAsc(self: *const App, a: u32, b: u32) bool {
        return self.keyOf(a) < self.keyOf(b);
    }
    fn lessDesc(self: *const App, a: u32, b: u32) bool {
        return self.keyOf(a) > self.keyOf(b);
    }

    /// Rebuilds the sorted row order when stale.
    pub fn ensureOrder(self: *App) []const u32 {
        const n = self.model.members.len;
        if (self.order.len != n) {
            self.gpa.free(self.order);
            self.order = self.gpa.alloc(u32, n) catch &.{};
            self.order_dirty = true;
        }
        if (self.order_dirty and self.order.len == n) {
            for (self.order, 0..) |*o, k| o.* = @intCast(k);
            if (self.sort_asc) {
                std.sort.pdq(u32, self.order, @as(*const App, self), lessAsc);
            } else {
                std.sort.pdq(u32, self.order, @as(*const App, self), lessDesc);
            }
            self.order_dirty = false;
        }
        return self.order;
    }

    pub fn sortBy(self: *App, col: SortCol, asc: bool) void {
        self.sort_col = col;
        self.sort_asc = asc;
        self.order_dirty = true;
    }
};
