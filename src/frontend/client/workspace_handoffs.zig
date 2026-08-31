//! Wires workspace handoff use cases to one client's protocol and resources.

const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const runtime_transport = @import("runtime_transport.zig");
const tab_attachments = @import("tab_attachments.zig");
const workspace_transitions = @import("workspace_transitions.zig");

const Client = @import("client.zig");
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const workspace_handoff = client_application.workspace_handoff;

/// Resolves one workspace selection from the committed list and requests its
/// handoff only when the target is known and actionable.
///
/// ```zig
/// _ = try selectWorkspace(client, .{ .position = 1 });
/// ```
pub fn selectWorkspace(client: *Client, target: workspace_handoff.SelectionTarget) !bool {
    var use_case = selectionHandler(client);

    return use_case.execute(target);
}

/// Requests a workspace by its stable runtime identity, preferring its last
/// focused pane when a navigation bookmark exists.
///
/// ```zig
/// _ = try requestWorkspace(client, workspace_id);
/// ```
pub fn requestWorkspace(client: *Client, workspace: schema.WorkspaceId) !client_model.WorkspaceDeparture {
    return request(client, .{
        .target = workspaceTarget(client, workspace),
        .fallback_workspace = workspace,
    }, false);
}

/// Follows a runtime-selected workspace after canonical state removed the
/// current projection. Stale requests cannot block this lifecycle transition.
///
/// ```zig
/// _ = try followWorkspace(client, workspace_id);
/// ```
pub fn followWorkspace(client: *Client, workspace: schema.WorkspaceId) !client_model.WorkspaceDeparture {
    if (client.model.workspaceLocation() != null) {
        return error.WorkspaceStillActive;
    }

    return request(client, .{
        .target = workspaceTarget(client, workspace),
        .fallback_workspace = workspace,
    }, true);
}

/// Requests a specific runtime pane, retaining its workspace only as the
/// recovery target when a stale navigation identity is possible.
///
/// ```zig
/// _ = try requestPane(client, pane_id, fallback_workspace);
/// ```
pub fn requestPane(client: *Client, pane_id: schema.PaneId, fallback_workspace: ?schema.WorkspaceId) !client_model.WorkspaceDeparture {
    return request(client, .{
        .target = .{ .pane = pane_id },
        .fallback_workspace = fallback_workspace,
    }, false);
}

const RequestPlan = struct {
    target: schema.PaneTarget,
    fallback_workspace: ?schema.WorkspaceId,
};

fn workspaceTarget(client: *const Client, workspace: schema.WorkspaceId) schema.PaneTarget {
    const destination: schema.WorkspaceLocation = .{ .workspace = workspace };

    return if (client.navigation_history.find(destination)) |bookmark|
        .{ .pane = bookmark.pane_id }
    else
        .{ .workspace = workspace };
}

fn request(client: *Client, plan: RequestPlan, ignore_pending: bool) !client_model.WorkspaceDeparture {
    var handler = requestHandler(client, ignore_pending);

    return handler.execute(.{
        .target = plan.target,
        .fallback_workspace = plan.fallback_workspace,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    });
}

fn requestHandler(client: *Client, ignore_pending: bool) workspace_handoff.RequestWorkspaceHandoffHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = if (ignore_pending) neverPending else requestPending,
        },
        .effects = .{
            .context = client,
            .detach = detachCurrent,
            .send = sendHandoff,
            .restore = restoreCurrent,
            .apply = releaseDeparture,
        },
    };
}

fn selectionHandler(client: *Client) workspace_handoff.SelectWorkspaceHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = requestPending,
        },
        .effects = .{
            .context = client,
            .request = requestSelectedWorkspace,
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
    return workspace_transitions.arrival(
        client,
        opened,
        multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    );
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
            .apply = activateArrival,
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
    return request_lifecycle.busy(client);
}

fn neverPending(_: *anyopaque) bool {
    return false;
}

fn requestSelectedWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try requestWorkspace(client, workspace);
}

fn detachCurrent(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var required_capacity: usize = 1;
    if (client.model.reportedPaneFocus()) |reported| {
        if (client.model.workspace.findPane(reported.pane_id)) |pane| {
            required_capacity += @intFromBool(reported.focus_events and pane.attached);
        }
    }
    if (client.model.panePasteSession()) |session| {
        required_capacity += @intFromBool(session.bracketed_paste);
    }

    var planned_tabs = client.model.workspace.tabIterator();
    while (planned_tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            required_capacity += @intFromBool(pane.attached);
        }
    }
    const available_capacity = runtime_transport.availableCapacity(client);
    if (required_capacity > available_capacity) {
        return error.ClientOutboxFull;
    }

    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        try tab_attachments.detach(client, tab.location);
    }
}

fn sendHandoff(context: *anyopaque, command: workspace_handoff.WorkspaceHandoff) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .initial_open = .{ .fallback_workspace = command.fallback_workspace } },
        },
        .message = .{ .open_pane = .{
            .request_id = request_id,
            .target = command.target,
            .size = command.size,
            .launch = null,
        } },
    });
}

fn restoreCurrent(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const active = client.model.workspace.active() orelse return;
    var panes = active.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    if (!request_lifecycle.has(client, .tab_snapshot)) {
        try request_lifecycle.requestTabSnapshot(client, active.location);
    }
}

fn releaseDeparture(context: *anyopaque, departure: *const client_model.WorkspaceDeparture) void {
    const client: *Client = @ptrCast(@alignCast(context));
    workspace_transitions.release(client, departure);
}

fn activateArrival(context: *anyopaque, command: client_model.WorkspaceArrival) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try workspace_transitions.activate(client, .{
        .pane_id = command.pane_id,
        .location = command.location,
    });
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(.{ .workspace = workspace });
}

fn retryWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .initial_open = .{} },
        },
        .message = .{ .open_pane = .{
            .request_id = request_id,
            .target = .{ .workspace = workspace },
            .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
            .launch = null,
        } },
    });
}
