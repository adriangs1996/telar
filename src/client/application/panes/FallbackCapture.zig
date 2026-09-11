const FallbackCapture = @This();
const source_namespace = @import("pane_graphics.zig");
const FallbackEffects = @import("FallbackEffects.zig");
const std = @import("std");
with_graphics: []const source_namespace.schema.PaneId,
queries: [3]source_namespace.schema.PaneId = undefined,
query_count: usize = 0,

pub fn port(capture: *FallbackCapture) FallbackEffects {
    return .{ .context = capture, .has_graphics = hasGraphics };
}

fn hasGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *FallbackCapture = @ptrCast(@alignCast(context));
    capture.queries[capture.query_count] = pane_id;
    capture.query_count += 1;

    return std.mem.findScalar(source_namespace.schema.PaneId, capture.with_graphics, pane_id) != null;
}
