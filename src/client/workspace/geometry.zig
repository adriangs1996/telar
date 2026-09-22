//! Geometry supplied by presentation, in pane-grid coordinates. Host pixels
//! are translated before entering application handlers.

const core = @import("telar-core");
const State = @import("State.zig");
const std = @import("std");

test "geometry changes invalidate captured input even when the area returns" {
    var state: State = .{};
    const area: core.Rect = .{ .x = 2, .y = 1, .w = 80, .h = 24 };
    state.update(area);
    const captured = state.current;
    state.update(area);
    try std.testing.expect(captured.matches(state.current));
    state.update(.{ .w = 10, .h = 10 });
    try std.testing.expect(!captured.matches(state.current));
    state.update(area);
    try std.testing.expect(!captured.matches(state.current));
}
