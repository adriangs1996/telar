const DeliverActivePaneResourcesHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ActivePaneResourceDeliveryEffects.zig");
const source_namespace = @import("active_pane_resource_delivery.zig");
const std = @import("std");
model: *client_model.Model,
effects: Effects,

/// Acknowledges a focused `done` agent, then reconciles only the focused
/// attachment shelf and re-offers geometry when its visibility changes
/// the workbench.
///
/// ```zig
/// _ = try handler.synchronizeAttachments();
/// ```
pub fn synchronizeAttachments(handler: *DeliverActivePaneResourcesHandler) !bool {
    if (handler.model.takeAgentAcknowledgement()) |key| {
        try handler.effects.acknowledge_agent(handler.effects.context, key);
    }

    const area = handler.effects.sync_attachment_target(
        handler.effects.context,
        handler.model.focusedAttachmentTarget(),
    ) orelse return false;

    try handler.effects.offer_pane_geometry(handler.effects.context, area);
    return true;
}

/// Synchronizes attachment geometry before child focus reporting.
///
/// ```zig
/// try handler.synchronize();
/// ```
pub fn synchronize(handler: *DeliverActivePaneResourcesHandler) !void {
    _ = try handler.synchronizeAttachments();
    try handler.effects.sync_focus_reporting(handler.effects.context);
}

/// Validates one committed focus and delivers its active-pane resources.
/// Fullscreen geometry follows attachment and focus-report synchronization,
/// then newly visible detached panes request runtime attachments.
///
/// ```zig
/// try handler.deliverFocus(focus, area);
/// ```
pub fn deliverFocus(handler: *DeliverActivePaneResourcesHandler, focus: client_model.PaneFocus, area: source_namespace.ui.Rect) !void {
    try handler.validateFocus(focus);
    try handler.synchronize();
    if (!focus.geometry_changed) {
        return;
    }

    handler.effects.invalidate_graphics_placements(handler.effects.context);
    try handler.effects.offer_pane_geometry(handler.effects.context, area);
    try handler.effects.request_visible_attachments(handler.effects.context, area);
}

fn validateFocus(handler: *const DeliverActivePaneResourcesHandler, focus: client_model.PaneFocus) !void {
    const active = handler.model.workspace.activeConst() orelse return error.StalePaneFocus;
    if (!std.meta.eql(active.location, focus.location) or
        active.model.layout.focused() != focus.focused or
        handler.model.version().panes != focus.panes_revision)
    {
        return error.StalePaneFocus;
    }
}
