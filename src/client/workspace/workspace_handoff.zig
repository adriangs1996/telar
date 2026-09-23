//! Workspace handoff: switches this client to another workspace and releases
//! the one it leaves.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_removal = @import("tab_removal.zig");
const tab_snapshot = @import("tab_snapshot.zig");
const workspace_list_snapshot = @import("workspace_list_snapshot.zig");
const Client = @import("../AttachedClient.zig");

const WorkspaceSwitchTarget = union(enum) { workspace: core.WorkspaceId, pane: data.PaneRequest };

const WorkspaceSwitchAuthority = enum { requested_departure, canonical_follow };

const WorkspaceRecovery = enum { retried, unrecoverable };

/// Selects a known inactive workspace only while this connection is idle.
/// Example: `_ = try workspace_handoff.selectWorkspace(app, .{ .position = 1 });`
pub fn selectWorkspace(client: *Client, target: data.WorkspaceSelectionTarget) !bool {
    if (!client.model.request_lifecycle.tracker.isEmpty()) {
        return false;
    }

    const workspace = switch (target) {
        .position => |position| client.model.workspace_list_snapshot.workspaceAtPosition(position) orelse return false,
        .workspace => |workspace| workspace,
    };

    if (!client.model.knowsWorkspace(workspace)) {
        return false;
    }

    if (client.model.workspace) |current| {
        switch (current) {
            .workspace => |active| {
                if (active == workspace) {
                    return false;
                }
            },
            .worktree => {},
        }
    }

    _ = try requestWorkspaceSwitch(
        client,
        .{
            .workspace = workspace,
        },
        .requested_departure,
    );

    return true;
}

/// Opens a workspace using its remembered pane, retaining a single fallback.
/// Example: `_ = try workspace_handoff.requestWorkspace(app, workspace_id);`
pub fn requestWorkspace(client: *Client, workspace: core.WorkspaceId) !data.WorkspaceDeparture {
    return requestWorkspaceSwitch(
        client,
        .{
            .workspace = workspace,
        },
        .requested_departure,
    );
}

/// Opens an exact remote pane with the containing workspace as optional fallback.
/// Example: `_ = try workspace_handoff.requestWorkspacePane(app, pane_id, workspace_id);`
pub fn requestWorkspacePane(client: *Client, pane_id: core.PaneId, fallback_workspace: ?core.WorkspaceId) !data.WorkspaceDeparture {
    return requestWorkspaceSwitch(
        client,
        .{
            .pane = .{
                .pane_id = pane_id,
                .fallback_workspace = fallback_workspace,
            },
        },
        .requested_departure,
    );
}

/// Preflights departure, queues the open, then retires the previous projection.
pub fn requestWorkspaceSwitch(client: *Client, target: WorkspaceSwitchTarget, authority: WorkspaceSwitchAuthority) !data.WorkspaceDeparture {
    const size = data.multiplexer.rectSize(client.geometry().area) orelse return error.TerminalTooSmall;
    const command: data.WorkspaceHandoff = switch (target) {
        .workspace => |workspace| selected: {
            const bookmark = client.model.navigation_history.find(
                .{
                    .workspace = workspace,
                },
            );
            break :selected .{
                .target = if (bookmark) |remembered| .{
                    .pane = remembered.pane_id,
                } else .{
                    .workspace = workspace,
                },
                .fallback_workspace = workspace,
                .size = size,
            };
        },
        .pane => |pane| .{
            .target = .{
                .pane = pane.pane_id,
            },
            .fallback_workspace = pane.fallback_workspace,
            .size = size,
        },
    };

    switch (authority) {
        .requested_departure => {
            if (!client.model.request_lifecycle.tracker.isEmpty()) {
                return error.WorkspaceSwitchWhileRequestPending;
            }
        },
        .canonical_follow => {
            if (client.model.workspace != null) {
                return error.WorkspaceStillActive;
            }
        },
    }

    try client.model.request_lifecycle.ensureCanStart(2);
    var required: usize = 1;
    for (client.model.tabs.location[0..client.model.tabs.count]) |location| {
        required += try tab_removal.tabDetachmentCapacity(&client.model, location);
    }

    if (required > client.model.to_runtime.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    for (client.model.tabs.location[0..client.model.tabs.count]) |location| {
        tab_removal.detachTab(client, location) catch |err| {
            restoreDepartingWorkspace(client) catch {};
            return err;
        };
    }

    sendWorkspaceOpen(&client.model, command) catch |err| {
        restoreDepartingWorkspace(client) catch {};
        return err;
    };

    const departure = client.model.departWorkspace();
    releaseWorkspace(client, &departure);
    return departure;
}

/// Repairs the visible tab after a partial departure; callers preserve the original error.
fn restoreDepartingWorkspace(client: *Client) !void {
    const location = client.model.activeTabLocation() orelse return;
    const plan = try client.model.planTabDetachment(location);
    for (plan.slice()) |pane| {
        try client.graphics.setPaneVisible(pane.pane_id, true);
    }

    _ = try tab_snapshot.recoverTabSnapshot(&client.model, location);
}

/// Retries a missing remembered pane once, clearing the fallback on the new request.
pub fn recoverWorkspaceSwitch(model: *data.ClientModel, fallback_workspace: ?core.WorkspaceId, code: core.FailureCode) !WorkspaceRecovery {
    const workspace = fallback_workspace orelse return .unrecoverable;
    if (code != .pane_not_found) {
        return .unrecoverable;
    }

    model.navigation_history.forget(
        .{
            .workspace = workspace,
        },
    );
    try sendWorkspaceOpen(
        model,
        .{
            .target = .{
                .workspace = workspace,
            },
            .fallback_workspace = null,
            .size = data.multiplexer.rectSize(data.workbench.region(model).area) orelse return error.TerminalTooSmall,
        },
    );
    return .retried;
}

/// Correlates the open before its owned message enters the runtime outbox.
fn sendWorkspaceOpen(model: *data.ClientModel, command: data.WorkspaceHandoff) !void {
    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .initial_open = .{
                        .fallback_workspace = command.fallback_workspace,
                    },
                },
            },
            .message = .{
                .open_pane = .{
                    .request_id = request_id,
                    .target = command.target,
                    .size = command.size,
                    .launch = null,
                },
            },
        },
    );
}

/// Restores a bookmark layout only when the runtime selected that exact tab.
pub fn workspaceArrival(history: *const data.NavigationHistory, opened: data.OpenedPane, size: core.TerminalSize) data.WorkspaceArrival {
    const bookmark = history.find(opened.location.workspace);
    const saved_layout = if (bookmark) |remembered|
        if (std.meta.eql(remembered.location, opened.location)) remembered.tab_layout else null
    else
        null;

    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .size = size,
        .saved_layout = saved_layout,
    };
}

/// Remembers departed navigation before releasing pane resources.
pub fn releaseWorkspace(client: *Client, departure: *const data.WorkspaceDeparture) void {
    if (departure.bookmark) |bookmark| {
        client.model.navigation_history.remember(
            .{
                .location = bookmark.location,
                .pane_id = bookmark.pane_id,
                .tab_layout = bookmark.tab_layout,
            },
        );
    }

    for (departure.panes.slice()) |pane_id| {
        pane_closure.releasePaneResources(client, pane_id);
    }

    _ = client.model.forgetReportedPaneFocus();
}

/// Validates the committed root before resuming input and requesting canonical snapshots.
pub fn activateWorkspace(client: *Client, activation: data.WorkspaceActivation) !void {
    const active = client.model.tabs.activeSlot() orelse return error.StaleWorkspaceActivation;
    const root = client.model.panes.findInConst(client.model.tabs.location[active].tab_id, activation.pane_id) orelse return error.StaleWorkspaceActivation;
    const version = client.model.version();
    if (!std.meta.eql(client.model.tabs.location[active], activation.location) or
        client.model.panes.countIn(client.model.tabs.location[active].tab_id) != 1 or
        client.model.tabs.layout[active].focused() != activation.pane_id or
        !std.meta.eql(root.location, activation.location) or
        !root.attached or
        version.workspace != activation.workspace_revision or
        version.tabs != activation.tabs_revision or
        version.active_tab != activation.active_tab_revision or
        version.panes != activation.panes_revision or
        version.copy != activation.copy_revision or
        activation.workspace_revision_before +% 1 != activation.workspace_revision or
        activation.tabs_revision_before +% 1 != activation.tabs_revision or
        activation.active_tab_revision_before +% 1 != activation.active_tab_revision or
        activation.panes_revision_before +% 1 != activation.panes_revision or
        activation.copy_revision_before +% @intFromBool(activation.copy_released) != activation.copy_revision)
    {
        return error.StaleWorkspaceActivation;
    }

    try pane_focus.synchronizeActivePane(client);
    client.model.to_host.resume_input = true;
    try workspace_list_snapshot.requestWorkspaceSnapshot(&client.model, activation.location.workspace);
    try tab_snapshot.requestTabSnapshot(&client.model, activation.location);
}
