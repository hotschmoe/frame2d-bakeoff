//! Frame2D analysis engine (SPEC 4): model, generator, RCM + skyline solver, JSON in/out.
pub const model = @import("model.zig");
pub const model_json = @import("model_json.zig");
pub const results_json = @import("results_json.zig");
pub const gen = @import("gen.zig");
pub const rcm = @import("rcm.zig");
pub const solver = @import("solver.zig");
pub const sweep = @import("sweep.zig");
pub const CountingAllocator = @import("counting_allocator.zig");

pub const Model = model.Model;
pub const Diag = model.Diag;
pub const Solver = solver.Solver;

test {
    _ = @import("tests.zig");
}
