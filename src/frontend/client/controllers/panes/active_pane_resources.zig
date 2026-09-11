//! Adapts active-pane resource commands to one concrete client.

const Client = @import("../../Client.zig");
const PaneFocusType = @import("telar-client").PaneFocus;
const RectType = @import("telar-core").Rect;
const DeliverActivePaneResourcesHandlerType = @import("telar-client").DeliverActivePaneResourcesHandler;
const AgentKeyType = @import("telar-client").AgentKey;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const TargetType = @import("telar-client").AttachmentTarget;
const pane_focus_reports = @import("pane_focus_reports.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const tab_snapshots = @import("../tabs/tab_snapshots.zig");
const pane_geometry = @import("pane_geometry.zig");

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
pub fn deliverFocus(client: *Client, focus: PaneFocusType, area: RectType) !void {
    var use_case = handler(client);

    try use_case.deliverFocus(focus, area);
}

fn handler(client: *Client) DeliverActivePaneResourcesHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .sync_attachment_target = syncAttachmentTarget,
            .sync_focus_reporting = syncFocusReporting,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
            .request_visible_attachments = requestVisibleAttachments,
            .acknowledge_agent = acknowledgeAgent,
        },
    };
}

fn acknowledgeAgent(raw_context: *anyopaque, key: AgentKeyType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try runtime_transport.enqueue(client, .{ .acknowledge_agent = .{
        .pane_id = key.pane_id,
        .pane_generation = key.pane_generation,
    } });
}

fn syncAttachmentTarget(raw_context: *anyopaque, target: ?TargetType) ?RectType {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    if (!client.view.syncAttachmentTarget(target)) {
        return null;
    }

    return client.geometry().area;
}

fn syncFocusReporting(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    _ = try pane_focus_reports.sync(client);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    kitty_delivery.invalidatePlacements(&client.graphics_store);
}

fn requestVisibleAttachments(raw_context: *anyopaque, area: RectType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try tab_snapshots.attachActive(client, area);
}

fn offerPaneGeometry(raw_context: *anyopaque, area: RectType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(client, area);
}
