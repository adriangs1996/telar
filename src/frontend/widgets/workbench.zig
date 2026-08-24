//! Hit-test projection for pane content rendered by the multiplexer.

const multiplexer = @import("../multiplexer.zig");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

pub fn register(
    context: *widget.Context,
    area: ui.Rect,
    model: *multiplexer.Model,
) void {
    for (model.layoutSnapshot(area).views()) |view|
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
}
