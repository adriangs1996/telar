const DeliverPaneViewportHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneViewportDeliveryEffects.zig");
model: *const client_model.Model,
effects: Effects,

/// Validates one exact viewport commit before synchronizing graphics and
/// then the runtime attachment.
///
/// ```zig
/// try handler.execute(change);
/// ```
pub fn execute(handler: *const DeliverPaneViewportHandler, change: client_model.PaneViewportChange) !void {
    const active = handler.model.workspace.activeConst() orelse return error.StalePaneViewport;
    const pane = active.model.findConst(change.pane_id) orelse return error.StalePaneViewport;
    if (!pane.attached or
        pane.scroll.offset != change.offset or
        pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
        handler.model.version().viewport != change.viewport_revision)
    {
        return error.StalePaneViewport;
    }

    try handler.effects.set_graphics_visible(
        handler.effects.context,
        change.pane_id,
        change.at_bottom,
    );
    try handler.effects.deliver_viewport(handler.effects.context, .{
        .pane_id = change.pane_id,
        .offset = change.offset,
    });
}
