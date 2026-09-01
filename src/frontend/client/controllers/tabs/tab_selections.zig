//! Wires semantic tab selection to one client's disposable resources.

const core = @import("telar-core");
const tabs_application = @import("../../application/tabs/root.zig");
const client_model = @import("../../model/root.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const pane_focus_reports = @import("../panes/pane_focus_reports.zig");
const pane_pastes = @import("../input/pane_pastes.zig");
const request_lifecycle = @import("../../request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("../../client.zig");
const schema = core.schema;
const select_tab = tabs_application.select_tab;
const tab_selection_delivery = tabs_application.tab_selection_delivery;

pub const Target = select_tab.Target;

/// Wires tab selection to snapshot gating and attachment synchronization.
///
/// ```zig
/// var use_case = selectionHandler(client);
/// _ = try use_case.execute(.{ .target = .{ .position = 1 } });
/// ```
pub fn selectionHandler(client: *Client) select_tab.SelectTabHandler {
    return .{
        .model = &client.model,
        .snapshots = .{
            .context = client,
            .pending = tabSnapshotPending,
        },
        .effects = .{
            .context = client,
            .deliver = deliverSelection,
        },
    };
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_snapshot);
}

fn deliverSelection(context: *anyopaque, selection: client_model.TabSelection) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: tab_selection_delivery.DeliverTabSelectionHandler = .{
        .model = &client.model,
        .paste_effects = pane_pastes.effects(client),
        .focus_effects = pane_focus_reports.effects(client),
        .attachment_effects = tab_attachments.effects(client),
        .effects = .{
            .context = client,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .request_tab_snapshot = requestTabSnapshot,
        },
    };

    try use_case.execute(selection);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
