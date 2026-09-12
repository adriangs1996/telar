//! Wires workspace handoff use cases to one client's protocol and resources.

const Client = @import("../../AttachedClient.zig");
const SelectionTargetType = @import("../../application/workspaces/workspace_handoff.zig").SelectionTarget;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const PaneIdType = @import("telar-core").PaneId;
const ApplicationWorkspacesWorkspaceHandoffTargetingTarget = @import("../../application/workspaces/workspace_handoff_targeting.zig").Target;
const ApplicationWorkspacesWorkspaceHandoffAdmissionAuthority = @import("../../application/workspaces/workspace_handoff_admission.zig").Authority;
const rectSize_module = @import("../../workspace/multiplexer.zig").rectSize;
const PlanWorkspaceHandoffHandlerType = @import("../../application/workspaces/PlanWorkspaceHandoffHandler.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const RequestWorkspaceHandoffHandlerType = @import("../../application/workspaces/RequestWorkspaceHandoffHandler.zig");
const tab_attachments = @import("../tabs/tab_attachments.zig");
const pane_pastes = @import("../input/pane_pastes.zig");
const pane_focus_reports = @import("../panes/pane_focus_reports.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("../../application/tabs/RequestTabSnapshotRecoveryHandler.zig");
const SelectWorkspaceHandlerType = @import("../../application/workspaces/SelectWorkspaceHandler.zig");
const OpenedPaneType = @import("../../application/panes/OpenedPane.zig");
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const workspace_transitions = @import("workspace_transitions.zig");
const ConfirmWorkspaceHandoffHandlerType = @import("../../application/workspaces/ConfirmWorkspaceHandoffHandler.zig");
const RecoverWorkspaceHandoffHandlerType = @import("../../application/workspaces/RecoverWorkspaceHandoffHandler.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const WorkspaceHandoffType = @import("../../application/workspaces/WorkspaceHandoff.zig");
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");

/// Resolves one workspace selection from the committed list and requests its
/// handoff only when the target is known and actionable.
///
/// ```zig
/// _ = try selectWorkspace(client, .{ .position = 1 });
/// ```
pub fn selectWorkspace(client: *Client, target: SelectionTargetType) !bool {
    var use_case = selectionHandler(client);

    return use_case.execute(target);
}

/// Requests a workspace by its stable runtime identity, preferring its last
/// focused pane when a navigation bookmark exists.
///
/// ```zig
/// _ = try requestWorkspace(client, workspace_id);
/// ```
pub fn requestWorkspace(client: *Client, workspace: WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .workspace = workspace }, .requested_departure);
}

/// Follows a runtime-selected workspace after canonical state removed the
/// current projection. Stale requests cannot block this lifecycle transition.
///
/// ```zig
/// _ = try followWorkspace(client, workspace_id);
/// ```
pub fn followWorkspace(client: *Client, workspace: WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .workspace = workspace }, .canonical_follow);
}

/// Requests a specific runtime pane, retaining its workspace only as the
/// recovery target when a stale navigation identity is possible.
///
/// ```zig
/// _ = try requestPane(client, pane_id, fallback_workspace);
/// ```
pub fn requestPane(client: *Client, pane_id: PaneIdType, fallback_workspace: ?WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .pane = .{
        .pane_id = pane_id,
        .fallback_workspace = fallback_workspace,
    } }, .requested_departure);
}

fn request(client: *Client, target: ApplicationWorkspacesWorkspaceHandoffTargetingTarget, authority: ApplicationWorkspacesWorkspaceHandoffAdmissionAuthority) !WorkspaceDepartureType {
    const targeting = targetingHandler(client);
    const plan = targeting.execute(target);
    var handler = requestHandler(client);

    return handler.execute(.{
        .target = plan.target,
        .fallback_workspace = plan.fallback_workspace,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
    }, authority);
}

fn targetingHandler(client: *Client) PlanWorkspaceHandoffHandlerType {
    return .{ .bookmarks = .{
        .context = client,
        .remembered_pane = rememberedPane,
    } };
}

fn rememberedPane(context: *anyopaque, workspace: WorkspaceLocationType) ?PaneIdType {
    const client: *Client = @ptrCast(@alignCast(context));
    const bookmark = client.navigation_history.find(workspace) orelse return null;

    return bookmark.pane_id;
}

fn requestHandler(client: *Client) RequestWorkspaceHandoffHandlerType {
    const attachment_effects = tab_attachments.effects(client);

    return .{
        .model = &client.model,
        .admission = .{
            .model = &client.model,
            .gate = .{
                .context = client,
                .pending = requestPending,
            },
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

fn snapshotRecovery(client: *Client) RequestTabSnapshotRecoveryHandlerType {
    return .{ .effects = .{
        .context = client,
        .pending = tabSnapshotPending,
        .request = requestTabSnapshot,
    } };
}

fn selectionHandler(client: *Client) SelectWorkspaceHandlerType {
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
pub fn arrival(client: *Client, opened: OpenedPaneType) !WorkspaceArrivalType {
    return workspace_transitions.arrival(
        client,
        opened,
        rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
    );
}

/// Wires a correlated `pane_opened` response to atomic model arrival and
/// post-commit focus and snapshot effects.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) ConfirmWorkspaceHandoffHandlerType {
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
pub fn recoveryHandler(client: *Client) RecoverWorkspaceHandoffHandlerType {
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

fn requestSelectedWorkspace(context: *anyopaque, workspace: WorkspaceIdType) !void {
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

fn sendHandoff(context: *anyopaque, command: WorkspaceHandoffType) !void {
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

fn showPaneGraphics(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics.setPaneVisible(pane_id, true);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}

fn releaseDeparture(context: *anyopaque, departure: *const WorkspaceDepartureType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    workspace_transitions.release(client, departure);
}

fn activateArrival(context: *anyopaque, activation: WorkspaceActivationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try workspace_transitions.activate(client, activation);
}

fn forgetWorkspace(context: *anyopaque, workspace: WorkspaceIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(.{ .workspace = workspace });
}

fn retryWorkspace(context: *anyopaque, workspace: WorkspaceIdType) !void {
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
            .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
            .launch = null,
        } },
    });
}
