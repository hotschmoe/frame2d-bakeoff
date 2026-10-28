//! Test root: pulls in every module's `test` blocks.
test {
    _ = @import("model.zig");
    _ = @import("solver.zig");
    _ = @import("engine.zig");
    _ = @import("ui.zig");
}
