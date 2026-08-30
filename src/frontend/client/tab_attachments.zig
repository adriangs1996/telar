//! Synchronizes client-owned pane attachments when the active tab changes.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const create_tab = client_application.create_tab;
const schema = core.schema;
const select_tab = client_application.select_tab;
const tabs_mod = workspace_capability.tabs;

/// Wires the tab-creation use case to this client's attachment port.
///
/// ```zig
/// var handler = creationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn creationHandler(client: *Client) create_tab.CreateTabHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyCreation,
        },
    };
}

/// Wires the tab-selection use case to this client's snapshot and attachment ports.
///
/// ```zig
/// var handler = selectionHandler(client);
/// _ = try handler.execute(.{ .tab_id = tab_id });
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
            .apply = applySelection,
        },
    };
}

/// Detaches every attached pane in a tab after clearing the reported focus.
///
/// ```zig
/// try detach(client, tab);
/// ```
pub fn detach(client: *Client, tab: *tabs_mod.Tab) !void {
    // Focus-out must leave before the pane detaches. Keeping both operations
    // here prevents callers from violating that protocol ordering.
    try client.clearPaneFocus();

    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        try client.enqueue(.{ .detach_pane = .{ .pane_id = pane.id } });
        try client.graphics_store.setPaneVisible(pane.id, false);
    }

    tabs_mod.Model.detachAll(tab);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_snapshot);
}

fn applyCreation(context: *anyopaque, creation: client_model.TabCreation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const workspace = &client.model.workspace;
    const previous = findTab(workspace, creation.previous) orelse
        return error.UnexpectedTabCreation;
    const created = findTab(workspace, creation.created) orelse
        return error.UnexpectedTabCreation;

    try detach(client, previous);
    try client.syncPaneFocus(&created.model);
}

fn applySelection(context: *anyopaque, selection: client_model.TabSelection) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const workspace = &client.model.workspace;
    const previous = findTab(workspace, selection.previous) orelse
        return error.UnexpectedTabSelection;
    const selected = findTab(workspace, selection.selected) orelse
        return error.UnexpectedTabSelection;

    try detach(client, previous);

    var visible = selected.model.paneIterator();
    while (visible.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    try client.syncPaneFocus(&selected.model);
    try client.requestTabSnapshot(selected.location);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
