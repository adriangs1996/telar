//! Adapts active-pane resource commands to one concrete client.

const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const attachments = @import("../../../attachments/root.zig");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model/root.zig");
const pane_focus_reports = @import("pane_focus_reports.zig");
const pane_geometry = @import("pane_geometry.zig");
const runtime_transport = @import("../../connection/runtime_transport.zig");

const Client = @import("../../client.zig");
const active_pane_resource_delivery = panes_application.active_pane_resource_delivery;
const ui = core.ui;

/// Synchronizes attachment geometry and child focus reporting from the active
/// focused pane.
///
/// ```zig
/// try synchronize(client);
/// ```
pub fn synchronize(client: *Client) !void {
    var use_case = handler(client);

    try use_case.synchronize();
}

/// Synchronizes only the focused attachment target and its geometry.
///
/// ```zig
/// _ = try synchronizeAttachments(client);
/// ```
pub fn synchronizeAttachments(client: *Client) !bool {
    var use_case = handler(client);

    return use_case.synchronizeAttachments();
}

/// Delivers resources for one committed pane-focus transition.
///
/// ```zig
/// try deliverFocus(client, focus, area);
/// ```
pub fn deliverFocus(client: *Client, focus: client_model.PaneFocus, area: ui.Rect) !void {
    var use_case = handler(client);

    try use_case.deliverFocus(focus, area);
}

fn handler(client: *Client) active_pane_resource_delivery.DeliverActivePaneResourcesHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .sync_attachment_target = syncAttachmentTarget,
            .sync_focus_reporting = syncFocusReporting,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
            .acknowledge_agent = acknowledgeAgent,
        },
    };
}

fn acknowledgeAgent(raw_context: *anyopaque, key: agents.AgentKey) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try runtime_transport.enqueue(client, .{ .acknowledge_agent = .{
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
    } });
}

fn syncAttachmentTarget(raw_context: *anyopaque, target: ?attachments.Target) ?ui.Rect {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    if (!client.view.syncAttachmentTarget(target)) {
        return null;
    }

    return client.view.workbench();
}

fn syncFocusReporting(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try pane_focus_reports.sync(client);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.graphics_store.invalidatePlacements();
}

fn offerPaneGeometry(raw_context: *anyopaque, area: ui.Rect) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(client, area);
}
