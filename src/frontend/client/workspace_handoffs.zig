//! Wires workspace handoff use cases to one client's protocol and resources.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const client_outbox = @import("outbox.zig");
const pane_resources = @import("pane_resources.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const workspace_handoff = client_application.workspace_handoff;

/// Requests a workspace by its stable runtime identity, preferring its last
/// focused pane when a navigation bookmark exists.
///
/// ```zig
/// _ = try requestWorkspace(client, workspace_id);
/// ```
pub fn requestWorkspace(client: *Client, workspace: schema.WorkspaceId) !client_model.WorkspaceDeparture {
    const destination: schema.WorkspaceLocation = .{ .workspace = workspace };
    const target: schema.PaneTarget = if (client.navigation_history.find(destination)) |bookmark|
        .{ .pane = bookmark.pane_id }
    else
        .{ .workspace = workspace };

    return request(client, target, workspace);
}

/// Requests a specific runtime pane, retaining its workspace only as the
/// recovery target when a stale navigation identity is possible.
///
/// ```zig
/// _ = try requestPane(client, pane_id, fallback_workspace);
/// ```
pub fn requestPane(client: *Client, pane_id: schema.PaneId, fallback_workspace: ?schema.WorkspaceId) !client_model.WorkspaceDeparture {
    return request(client, .{ .pane = pane_id }, fallback_workspace);
}

fn request(client: *Client, target: schema.PaneTarget, fallback_workspace: ?schema.WorkspaceId) !client_model.WorkspaceDeparture {
    var handler = requestHandler(client);

    return handler.execute(.{
        .target = target,
        .fallback_workspace = fallback_workspace,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    });
}

fn requestHandler(client: *Client) workspace_handoff.RequestWorkspaceHandoffHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = requestPending,
        },
        .effects = .{
            .context = client,
            .detach = detachCurrent,
            .send = sendHandoff,
            .restore = restoreCurrent,
            .apply = applyDeparture,
        },
    };
}

/// Builds the confirmed arrival command with an exact saved layout, when one
/// still describes the pane and tab selected by the runtime.
///
/// ```zig
/// try confirmationHandler(client).execute(try arrival(client, opened));
/// ```
pub fn arrival(client: *Client, opened: schema.PaneOpened) !client_model.WorkspaceArrival {
    const saved_layout = if (client.navigation_history.find(opened.location.workspace)) |bookmark|
        if (std.meta.eql(bookmark.location, opened.location)) bookmark.tab_layout else null
    else
        null;

    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        .saved_layout = saved_layout,
    };
}

/// Wires a correlated `pane_opened` response to atomic model arrival and
/// post-commit focus and snapshot effects.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) workspace_handoff.ConfirmWorkspaceHandoffHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyArrival,
        },
    };
}

/// Wires a failed remembered-pane lookup to one workspace-targeted retry.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(failure);
/// ```
pub fn recoveryHandler(client: *Client) workspace_handoff.RecoverWorkspaceHandoffHandler {
    return .{
        .effects = .{
            .context = client,
            .forget = forgetWorkspace,
            .retry = retryWorkspace,
        },
    };
}

fn requestPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.count != 0;
}

fn detachCurrent(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var required_capacity: usize = 1;
    required_capacity += @intFromBool(client.reported_focus_events);
    var planned_tabs = client.model.workspace.tabIterator();
    while (planned_tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            required_capacity += @intFromBool(pane.attached);
        }
    }
    const available_capacity = client_outbox.capacity - @as(usize, client.outbox.len);
    if (required_capacity > available_capacity) {
        return error.ClientOutboxFull;
    }

    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        try tab_attachments.detach(client, tab);
    }
}

fn sendHandoff(context: *anyopaque, command: workspace_handoff.WorkspaceHandoff) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .initial_open = .{ .fallback_workspace = command.fallback_workspace } },
        .{ .open_pane = .{
            .request_id = request_id,
            .target = command.target,
            .size = command.size,
            .launch = null,
        } },
    );
}

fn restoreCurrent(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const active = client.model.workspace.active() orelse return;
    var panes = active.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    if (!client.requests.has(.tab_snapshot)) {
        try client.requestTabSnapshot(active.location);
    }
}

fn applyDeparture(context: *anyopaque, departure: *const client_model.WorkspaceDeparture) void {
    const client: *Client = @ptrCast(@alignCast(context));
    if (departure.bookmark) |bookmark| {
        client.navigation_history.remember(.{
            .location = bookmark.location,
            .pane_id = bookmark.pane_id,
            .tab_layout = bookmark.tab_layout,
        });
    }

    for (departure.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }
}

fn applyArrival(context: *anyopaque, command: client_model.WorkspaceArrival) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const active = client.model.workspace.active() orelse return error.UnexpectedRequest;
    if (!std.meta.eql(active.location, command.location) or
        active.model.find(command.pane_id) == null)
    {
        return error.UnexpectedRequest;
    }

    try client.syncPaneFocus(&active.model);
    try client.scheduleInputRead();
    try client.requestWorkspaceSnapshot(command.location.workspace);
    try client.requestTabSnapshot(command.location);
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(.{ .workspace = workspace });
}

fn retryWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .initial_open = .{} },
        .{ .open_pane = .{
            .request_id = request_id,
            .target = .{ .workspace = workspace },
            .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
            .launch = null,
        } },
    );
}
