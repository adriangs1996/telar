const ModelType = @import("../../model/Model.zig");
const SidebarLayoutDeliveryEffects = @import("SidebarLayoutDeliveryEffects.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const DeliverSidebarLayoutHandler = @This();

model: *ModelType,
effects: SidebarLayoutDeliveryEffects,

/// Validates one exact sidebar commit before projecting the view,
/// invalidating graphics and re-offering active pane geometry.
///
/// ```zig
/// try handler.execute(change);
/// ```
pub fn execute(handler: *const DeliverSidebarLayoutHandler, change: SidebarLayoutType) !void {
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
