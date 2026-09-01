//! Wires workspace handoff use cases to one client's protocol and resources.

const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus_reports = @import("pane_focus_reports.zig");
const pane_pastes = @import("pane_pastes.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const runtime_transport = @import("runtime_transport.zig");
const tab_attachments = @import("tab_attachments.zig");
const workspace_transitions = @import("workspace_transitions.zig");

const Client = @import("client.zig");
const multiplexer = workspace_capability.multiplexer;
const pane_open_delivery = client_application.pane_open_delivery;
const schema = core.schema;
const tab_snapshot_recovery = client_application.tab_snapshot_recovery;
const workspace_handoff = client_application.workspace_handoff;
const workspace_handoff_targeting = client_application.workspace_handoff_targeting;

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
    return request(client, .{ .workspace = workspace }, false);
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

    return request(client, .{ .workspace = workspace }, true);
}

/// Requests a specific runtime pane, retaining its workspace only as the
/// recovery target when a stale navigation identity is possible.
///
/// ```zig
/// _ = try requestPane(client, pane_id, fallback_workspace);
/// ```
pub fn requestPane(client: *Client, pane_id: schema.PaneId, fallback_workspace: ?schema.WorkspaceId) !client_model.WorkspaceDeparture {
    return request(client, .{ .pane = .{
        .pane_id = pane_id,
        .fallback_workspace = fallback_workspace,
    } }, false);
}

fn request(client: *Client, target: workspace_handoff_targeting.Target, ignore_pending: bool) !client_model.WorkspaceDeparture {
    const targeting = targetingHandler(client);
    const plan = targeting.execute(target);
    var handler = requestHandler(client, ignore_pending);

    return handler.execute(.{
        .target = plan.target,
        .fallback_workspace = plan.fallback_workspace,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
    });
}

fn targetingHandler(client: *Client) workspace_handoff_targeting.PlanWorkspaceHandoffHandler {
    return .{ .bookmarks = .{
        .context = client,
        .remembered_pane = rememberedPane,
    } };
}

fn rememberedPane(context: *anyopaque, workspace: schema.WorkspaceLocation) ?schema.PaneId {
    const client: *Client = @ptrCast(@alignCast(context));
    const bookmark = client.navigation_history.find(workspace) orelse return null;

    return bookmark.pane_id;
}

fn requestHandler(client: *Client, ignore_pending: bool) workspace_handoff.RequestWorkspaceHandoffHandler {
    const attachment_effects = tab_attachments.effects(client);

    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = if (ignore_pending) neverPending else requestPending,
        },
        .preparation = .{
            .model = &client.model,
            .requests = .{
                .context = client,
                .ensure = ensureHandoffRequests,
            },
            .deliveries = .{
                .context = client,
                .available = availableDeliveryCapacity,
            },
            .pending_attachments = .{
                .context = attachment_effects.context,
                .pending = attachment_effects.attachment_pending,
            },
        },
        .retirement = .{
            .model = &client.model,
            .paste_effects = pane_pastes.effects(client),
            .focus_effects = pane_focus_reports.effects(client),
            .attachment_effects = attachment_effects,
        },
        .restoration = .{
            .effects = .{
                .context = client,
                .show_pane_graphics = showPaneGraphics,
            },
            .snapshots = snapshotRecovery(client),
        },
        .effects = .{
            .context = client,
            .send = sendHandoff,
            .release = releaseDeparture,
        },
    };
}

fn snapshotRecovery(client: *Client) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
    return .{ .effects = .{
        .context = client,
        .pending = tabSnapshotPending,
        .request = requestTabSnapshot,
    } };
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
pub fn arrival(client: *Client, opened: pane_open_delivery.OpenedPane) !client_model.WorkspaceArrival {
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
        .delivery = .{
            .context = client,
            .deliver = activateArrival,
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

fn ensureHandoffRequests(context: *anyopaque, count: u64) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.ensureCanStart(client, count);
}

fn availableDeliveryCapacity(context: *anyopaque) usize {
    const client: *Client = @ptrCast(@alignCast(context));

    return runtime_transport.availableCapacity(client);
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

fn showPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, true);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}

fn releaseDeparture(context: *anyopaque, departure: *const client_model.WorkspaceDeparture) void {
    const client: *Client = @ptrCast(@alignCast(context));
    workspace_transitions.release(client, departure);
}

fn activateArrival(context: *anyopaque, activation: client_model.WorkspaceActivation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try workspace_transitions.activate(client, activation);
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
