//! Wires tab-close and tab-removal use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const client_outbox = @import("outbox.zig");
const client_requests = @import("requests.zig");
const pane_resources = @import("pane_resources.zig");
const tab_attachments = @import("tab_attachments.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");

const Client = @import("client.zig");
const close_tab = client_application.close_tab;
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const RemovalTrigger = close_tab.RemovalTrigger;

/// Wires an interactive close to bounded delivery and provisional attachment
/// recovery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute()) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) close_tab.RequestCloseTabHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .prepare = prepareClose,
            .detach = detachForClose,
            .send = sendClose,
            .restore = restoreClose,
        },
    };
}

/// Wires close-request rejection to canonical attachment recovery.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(location);
/// ```
pub fn recoveryHandler(client: *Client) close_tab.RecoverCloseTabHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .restore = restoreClose,
        },
    };
}

/// Removes request-only protocol data from one canonical removal message.
///
/// ```zig
/// const command = removal(closed, .lifecycle);
/// ```
pub fn removal(closed: schema.TabClosed, trigger: RemovalTrigger) close_tab.ApplyTabRemoval {
    return .{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    };
}

/// Wires a canonical tab removal to request, resource and workspace effects.
///
/// ```zig
/// var handler = removalHandler(client);
/// const directive = try handler.execute(command);
/// ```
pub fn removalHandler(client: *Client) close_tab.ApplyTabRemovalHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .retire_requests = retireRequests,
            .release_resources = releaseResources,
            .forget_workspace = forgetWorkspace,
            .request_workspace = requestWorkspace,
        },
    };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn prepareClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, location) orelse return error.UnexpectedTabClosure;

    if (client.next_request_id == 0 or client.next_request_id >= std.math.maxInt(u64) - 1) {
        return error.RequestIdExhausted;
    }
    if (client.requests.count >= client_requests.Tracker.capacity) {
        return error.TooManyPendingRequests;
    }

    var required_capacity: usize = 1;
    if (client.reported_focus_events) {
        if (client.reported_focus) |pane_id| {
            if (client.model.workspace.findPane(pane_id)) |pane| {
                required_capacity += @intFromBool(pane.attached);
            }
        }
    }

    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        const attachment_pending = client.requests.hasPane(.attachment, pane.id);
        required_capacity += @intFromBool(pane.attached or attachment_pending);
    }

    const available_capacity = client_outbox.capacity - @as(usize, client.outbox.len);
    if (required_capacity > available_capacity) {
        return error.ClientOutboxFull;
    }
}

fn detachForClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, location) orelse return error.UnexpectedTabClosure;

    try tab_attachments.detach(client, tab);
}

fn sendClose(context: *anyopaque, intent: close_tab.TabCloseIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();

    try client.enqueueRequest(
        request_id,
        .{ .close_tab = intent.location },
        .{ .close_tab = .{
            .request_id = request_id,
            .location = intent.location,
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

fn retireRequests(context: *anyopaque, location: schema.TabLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.requests.ignoreTab(location.tab_id);
}

fn releaseResources(context: *anyopaque, removal_result: client_model.TabRemoval) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    for (removal_result.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    if (!removal_result.was_active) {
        return;
    }

    client.forgetPaneFocus();
    const active_location = removal_result.active orelse return;
    const active = findTab(&client.model.workspace, active_location) orelse return error.UnexpectedTabRemoval;

    var panes = active.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    try client.syncPaneFocus(&active.model);
    if (!client.requests.has(.tab_snapshot)) {
        try client.requestTabSnapshot(active.location);
    }
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(workspace);
}

fn requestWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = try workspace_handoffs.followWorkspace(client, workspace);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
