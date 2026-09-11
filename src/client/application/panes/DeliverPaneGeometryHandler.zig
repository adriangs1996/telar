const DeliverPaneGeometryHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("PaneGeometryDeliveryEffects.zig");
const std = @import("std");
const OfferPaneGeometryHandler = @import("OfferPaneGeometryHandler.zig");
model: *client_model.Model,
effects: Effects,

/// Validates one committed geometry change before invalidating placements
/// and offering its visible attached pane sizes, then requests attachments
/// for detached panes revealed by the new geometry.
///
/// ```zig
/// const count = try handler.execute(change);
/// ```
pub fn execute(handler: *DeliverPaneGeometryHandler, change: client_model.PaneGeometryChange) !usize {
    const active = handler.model.workspace.active() orelse return error.StalePaneGeometry;
    if (!std.meta.eql(active.location, change.location) or
        active.model.layout.focused() != change.focused or
        active.model.layout.isFullscreen() != change.fullscreen or
        handler.model.version().panes != change.panes_revision)
    {
        return error.StalePaneGeometry;
    }

    handler.effects.invalidate_graphics_placements(handler.effects.context);
    var offer: OfferPaneGeometryHandler = .{ .effects = .{
        .context = handler.effects.context,
        .deliver_resize = handler.effects.deliver_resize,
        .bottom_reservation = handler.effects.bottom_reservation,
    } };

    const count = try offer.execute(&active.model, change.area);
    try handler.effects.request_visible_attachments(handler.effects.context, change.area);

    return count;
}
