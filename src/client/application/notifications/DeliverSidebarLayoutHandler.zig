const DeliverSidebarLayoutHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("SidebarLayoutDeliveryEffects.zig");
model: *client_model.Model,
effects: Effects,

/// Validates one exact sidebar commit before projecting the view,
/// invalidating graphics and re-offering active pane geometry.
///
/// ```zig
/// try handler.execute(change);
/// ```
pub fn execute(handler: *const DeliverSidebarLayoutHandler, change: client_model.SidebarLayout) !void {
    if (handler.model.sidebarVisible() != change.visible or handler.model.sidebarWidth() != change.width or
        handler.model.version().chrome != change.chrome_revision)
    {
        return error.StaleSidebarLayout;
    }

    handler.effects.project_view(handler.effects.context, change.visible, change.width);
    handler.effects.invalidate_graphics_placements(handler.effects.context);
    const active = handler.model.workspace.active() orelse return;

    try handler.effects.offer_pane_geometry(handler.effects.context, &active.model);
}
