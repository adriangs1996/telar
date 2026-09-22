//! Workspace selection, bounded departure, arrival and remembered-pane recovery.

const tab_detachment = @import("../../tab_detachment.zig");
const Client = @import("../../AttachedClient.zig");
const SelectionTargetType = @import("../../application/workspaces/workspace_handoff.zig").SelectionTarget;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const PaneIdType = @import("telar-core").PaneId;
const ApplicationWorkspacesWorkspaceHandoffTargetingTarget = @import("../../application/workspaces/workspace_handoff_targeting.zig").Target;
const ApplicationWorkspacesWorkspaceHandoffAdmissionAuthority = @import("../../application/workspaces/workspace_handoff_admission.zig").Authority;
const rectSize_module = @import("../../workspace/multiplexer.zig").rectSize;
const OpenedPaneType = @import("../../application/panes/OpenedPane.zig");
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const workspace_transitions = @import("workspace_transitions.zig");
const WorkspaceHandoffType = @import("../../application/workspaces/WorkspaceHandoff.zig");

const Plan = @import("../../application/workspaces/Plan.zig");
const WorkspaceHandoffFailure = @import("../../application/workspaces/WorkspaceHandoffFailure.zig");

const WorkspaceRecovery = @import("../../application/workspaces/workspace_handoff.zig").WorkspaceRecovery;

/// Resolves a listed workspace and requests a handoff only while idle. Example: `_ = try selectWorkspace(client, .{ .position = 1 });`
pub fn selectWorkspace(client: *Client, target: SelectionTargetType) !bool {
    if (!client.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    const workspace = switch (target) {
        .position => |position| client.model.workspaceAtPosition(position) orelse return false,
        .workspace => |workspace| workspace,
    };
    if (!client.model.knowsWorkspace(workspace)) {
        return false;
    }
    if (client.model.workspaceLocation()) |current| {
        switch (current) {
            .workspace => |active| {
                if (active == workspace) {
                    return false;
                }
            },
            .worktree => {},
        }
    }

    _ = try requestWorkspace(client, workspace);

    return true;
}

/// Requests an exact runtime destination through the bounded handoff transaction. Example: `_ = try requestWorkspace(client, destination);`
pub fn requestWorkspace(client: *Client, workspace: WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .workspace = workspace }, .requested_departure);
}

/// Requests an exact runtime destination through the bounded handoff transaction. Example: `_ = try followWorkspace(client, destination);`
pub fn followWorkspace(client: *Client, workspace: WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .workspace = workspace }, .canonical_follow);
}

/// Requests an exact runtime destination through the bounded handoff transaction. Example: `_ = try requestPane(client, pane_id, fallback_workspace);`
pub fn requestPane(client: *Client, pane_id: PaneIdType, fallback_workspace: ?WorkspaceIdType) !WorkspaceDepartureType {
    return request(client, .{ .pane = .{
        .pane_id = pane_id,
        .fallback_workspace = fallback_workspace,
    } }, .requested_departure);
}

fn request(client: *Client, target: ApplicationWorkspacesWorkspaceHandoffTargetingTarget, authority: ApplicationWorkspacesWorkspaceHandoffAdmissionAuthority) !WorkspaceDepartureType {
    const plan: Plan = switch (target) {
        .workspace => |workspace| planned: {
            const bookmark = client.navigation_history.find(.{ .workspace = workspace });
            break :planned .{
                .target = if (bookmark) |remembered| .{ .pane = remembered.pane_id } else .{ .workspace = workspace },
                .fallback_workspace = workspace,
            };
        },
        .pane => |pane| .{ .target = .{ .pane = pane.pane_id }, .fallback_workspace = pane.fallback_workspace },
    };
    const command: WorkspaceHandoffType = .{
        .target = plan.target,
        .fallback_workspace = plan.fallback_workspace,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
    };

    switch (authority) {
        .requested_departure => {
            if (!client.request_lifecycle.tracker.isEmpty()) {
                return error.WorkspaceSwitchWhileRequestPending;
            }
        },
        .canonical_follow => {
            if (client.model.workspaceLocation() != null) {
                return error.WorkspaceStillActive;
            }
        },
    }

    try client.request_lifecycle.ensureCanStart(2);
    var required: usize = 1;
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        const detachment = try client.model.planTabDetachment(tab.location);
        required += tab_detachment.requiredCapacity(&detachment, &client.request_lifecycle.tracker);
    }

    if (required > client.runtime_transport.outbox.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        client.detachTab(tab.location) catch |err| {
            restore(client) catch {};
            return err;
        };
    }

    sendHandoff(client, command) catch |err| {
        restore(client) catch {};
        return err;
    };

    const departure = client.model.departWorkspace();
    workspace_transitions.release(client, &departure);
    return departure;
}

fn restore(client: *Client) !void {
    const location = client.model.activeTabLocation() orelse return;
    const plan = try client.model.planTabDetachment(location);
    for (plan.slice()) |pane| {
        try client.graphics.setPaneVisible(pane.pane_id, true);
    }

    _ = try client.recoverTabSnapshot(location);
}

/// Constructs the exact runtime arrival with the remembered tab layout. Example: `try confirm(client, try arrival(client, opened));`
pub fn arrival(client: *Client, opened: OpenedPaneType) !WorkspaceArrivalType {
    return workspace_transitions.arrival(
        client,
        opened,
        rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
    );
}

/// Commits arrival before activating resources; a delivery failure never rolls it back. Example: `try confirm(client, command);`
pub fn confirm(client: *Client, command: WorkspaceArrivalType) !void {
    const activation = try client.model.arriveWorkspace(command);
    try workspace_transitions.activate(client, activation);
}

/// Retries the containing workspace once when its remembered pane disappeared. Example: `_ = try recover(client, failure);`
pub fn recover(client: *Client, failure: WorkspaceHandoffFailure) !WorkspaceRecovery {
    const workspace = failure.fallback_workspace orelse return .unrecoverable;
    if (failure.code != .pane_not_found) {
        return .unrecoverable;
    }

    client.navigation_history.forget(.{ .workspace = workspace });
    try sendHandoff(client, .{
        .target = .{ .workspace = workspace },
        .fallback_workspace = null,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
    });
    return .retried;
}

fn sendHandoff(client: *Client, command: WorkspaceHandoffType) !void {
    const request_id = try client.request_lifecycle.nextId();
    try client.sendRuntimeRequest(.{
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
