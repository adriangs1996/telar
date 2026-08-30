//! Synchronizes client-owned pane attachments when the active tab changes.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_resources = @import("pane_resources.zig");

const Client = @import("client.zig");
const close_tab = client_application.close_tab;
const schema = core.schema;
const select_tab = client_application.select_tab;
const tabs_mod = workspace_capability.tabs;

/// Wires the close request to delivery and provisional-detach recovery.
///
/// ```zig
/// var handler = closeRequestHandler(client);
/// _ = try handler.execute();
/// ```
pub fn closeRequestHandler(client: *Client) close_tab.RequestCloseTabHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .detach = detachForClose,
            .send = sendClose,
            .restore = restoreClose,
        },
    };
}

/// Wires close-request rejection to attachment recovery.
///
/// ```zig
/// var handler = closeRecoveryHandler(client);
/// _ = try handler.execute(location);
/// ```
pub fn closeRecoveryHandler(client: *Client) close_tab.RecoverCloseTabHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .restore = restoreClose,
        },
    };
}

/// Wires canonical tab removal to graphics, focus and snapshot effects.
///
/// ```zig
/// var handler = closureHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn closureHandler(client: *Client) close_tab.CloseTabHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyClosure,
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

/// Detaches every attached or in-flight pane after clearing reported focus.
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
        const attachment_pending = client.requests.hasPane(.attachment, pane.id);
        if (!pane.attached and !attachment_pending) {
            continue;
        }

        try client.enqueue(.{ .detach_pane = .{ .pane_id = pane.id } });
        _ = client.requests.ignoreAttachment(pane.id);
        try client.graphics_store.setPaneVisible(pane.id, false);
    }

    tabs_mod.Model.detachAll(tab);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_snapshot);
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn detachForClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, location) orelse
        return error.UnexpectedTabClosure;

    try detach(client, tab);
}

fn sendClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .close_tab = location },
        .{ .close_tab = .{
            .request_id = request_id,
            .location = location,
        } },
    );
}

fn restoreClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    if (client.requests.has(.tab_snapshot)) {
        return;
    }

    try client.requestTabSnapshot(location);
}

fn applyClosure(context: *anyopaque, removal: client_model.TabRemoval) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.requests.ignoreTab(removal.removed.tab_id);

    for (removal.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    if (!removal.was_active) {
        return;
    }

    client.forgetPaneFocus();
    const active_location = removal.active orelse return;
    const active = findTab(&client.model.workspace, active_location) orelse
        return error.UnexpectedTabClosure;
    var panes = active.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    try client.syncPaneFocus(&active.model);
    if (!client.requests.has(.tab_snapshot)) {
        try client.requestTabSnapshot(active.location);
    }
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
