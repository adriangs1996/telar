const PaneIdType = @import("telar-core").PaneId;
const FallbackEffects = @import("FallbackEffects.zig");
const std = @import("std");
const FallbackCapture = @This();

with_graphics: []const PaneIdType,
queries: [3]PaneIdType = undefined,
query_count: usize = 0,

pub fn port(capture: *FallbackCapture) FallbackEffects {
    return .{ .context = capture, .has_graphics = hasGraphics };
}

fn hasGraphics(context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *FallbackCapture = @ptrCast(@alignCast(context));
    capture.queries[capture.query_count] = pane_id;
    capture.query_count += 1;

    return std.mem.findScalar(PaneIdType, capture.with_graphics, pane_id) != null;
}
