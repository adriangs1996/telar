//! Hit-test projection for pane content rendered by the multiplexer.

const layout = @import("../layout.zig");
const multiplexer = @import("../multiplexer.zig");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

pub fn register(
    context: *widget.Context,
    area: ui.Rect,
    model: *const multiplexer.Model,
) void {
    var views: [multiplexer.max_panes]layout.View = undefined;
    for (model.layout.views(area, &views)) |view|
        context.hits.add(view.outer, .{ .focus_pane = view.pane_id });
}
