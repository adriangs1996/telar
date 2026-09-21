//! Runtime tabs operations, reached from requests.dispatch.

const Application = @import("../Application.zig");
const CreateTab = @import("../commands/CreateTab.zig");
const CreateTabResult = @import("../commands/CreateTabResult.zig");
const create_tab = @import("../commands/create_tab.zig");
const CreateTabFailure = @import("../../entrypoints/requests/CreateTabFailure.zig");
const PendingTabCreatedType = @import("../../delivery/PendingTabCreated.zig");
const RenameTab = @import("../commands/RenameTab.zig");
const PendingTabRenamedType = @import("../../delivery/PendingTabRenamed.zig");
const RenameTabFailure = @import("../../entrypoints/requests/RenameTabFailure.zig");
const commands = @import("../../../workspace/commands.zig");
const MoveTab = @import("../commands/MoveTab.zig");
const MoveTabFailure = @import("../../entrypoints/requests/MoveTabFailure.zig");
const CloseTab = @import("../commands/CloseTab.zig");
const TabSnapshotRequest = @import("../queries/TabSnapshotRequest.zig");
const TabSnapshotResult = @import("../queries/TabSnapshotResult.zig");
const RequestTabSnapshotType = @import("telar-core").RequestTabSnapshot;
const RequestIdType = @import("telar-core").RequestId;
const CreateTabViewType = @import("telar-core").CreateTabView;
const RenameTabType = @import("telar-core").RenameTab;
const CloseTabType = @import("telar-core").CloseTab;
const MoveTabType = @import("telar-core").MoveTab;
const std = @import("std");
const launch_cwd_module = @import("../../client/launch_cwd.zig");
const CreateTabPrepareLaunch = @import("../commands/CreateTabPrepareLaunch.zig");
const CreateTabLaunchedPane = @import("../commands/CreateTabLaunchedPane.zig");
const CreateTabLaunchPane = @import("../commands/CreateTabLaunchPane.zig");
const TabCreatedType = @import("../../../workspace/TabCreated.zig");
const TabRenamedType = @import("../../../workspace/TabRenamed.zig");
const TabMovedType = @import("../../../workspace/TabMoved.zig");
const TabRemovedType = @import("../../../workspace/TabRemoved.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try tabs.routeRequestTabSnapshot(request, wire);`.
pub fn routeRequestTabSnapshot(request: *RequestContext, wire: RequestTabSnapshotType) !void {
    const snapshot = requestTabSnapshot(request, .{ .location = wire.location }) catch |err| {
        if (err == error.TabNotFound) {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .tab_not_found,
                .message = "tab not found",
            } });
            return;
        }

        return err;
    };

    try request.session.delivery.responses.push(.{ .tab_snapshot = .{
        .request_id = wire.request_id,
        .location = snapshot.location,
    } });
}

/// Example: `try tabs.routeCreateTab(request, wire);`.
pub fn routeCreateTab(request: *RequestContext, wire: CreateTabViewType) !void {
    const result = createTab(request, .{
        .workspace = wire.workspace,
        .kind = wire.kind,
        .label = wire.label,
        .size = wire.size,
        .launch = wire.launch,
    }) catch |err| {
        const failure: CreateTabFailure = switch (err) {
            error.WorkspaceNotFound => .{ .code = .workspace_not_found, .message = "workspace not found" },
            error.TabLimitReached => .{ .code = .resource_limit, .message = "tab limit reached" },
            error.InvalidTabLabel => .{ .code = .invalid_request, .message = "invalid tab label" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is leased by another client" },
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            else => return err,
        };

        try createTabQueueFailure(request, wire.request_id, failure);
        return;
    };

    const label = result.created.labelSlice();
    var pending: PendingTabCreatedType = .{
        .request_id = wire.request_id,
        .location = result.created.location,
        .position = result.created.position,
        .label = undefined,
        .label_len = @intCast(label.len),
        .root_pane_id = result.root_pane_id,
        .kind = result.kind,
        .pane_generation = result.pane_generation,
    };
    @memcpy(pending.label[0..label.len], label);
    try request.session.delivery.responses.push(.{ .tab_created = pending });
}

/// Example: `try tabs.routeRenameTab(request, wire);`.
pub fn routeRenameTab(request: *RequestContext, wire: RenameTabType) !void {
    const renamed = renameTab(request, .{
        .location = wire.location,
        .label = wire.label,
    }) catch |err| {
        switch (err) {
            error.TabNotFound => try renameTabQueueFailure(request, wire.request_id, .{
                .code = .tab_not_found,
                .message = "tab not found",
            }),
            error.InvalidTabLabel => try renameTabQueueFailure(request, wire.request_id, .{
                .code = .invalid_request,
                .message = "invalid tab label",
            }),
            else => return err,
        }

        return;
    };

    const label = renamed.labelSlice();
    var pending: PendingTabRenamedType = .{
        .request_id = wire.request_id,
        .location = renamed.location,
        .label = undefined,
        .label_len = @intCast(label.len),
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try request.session.delivery.responses.push(.{ .tab_renamed = pending });
}

/// Example: `try tabs.routeCloseTab(request, wire);`.
pub fn routeCloseTab(request: *RequestContext, wire: CloseTabType) !void {
    const removed = closeTab(request, .{ .location = wire.location }) catch |err| {
        switch (err) {
            error.TabNotFound => try closeTabQueueTabNotFound(request, wire.request_id),
            else => return err,
        }

        return;
    };

    try request.session.delivery.responses.push(.{ .tab_closed = .{
        .request_id = wire.request_id,
        .location = removed.location,
        .workspace_closed = removed.workspace_removed,
        .previous_workspace = removed.previous_workspace,
    } });
}

/// Example: `try tabs.routeMoveTab(request, wire);`.
pub fn routeMoveTab(request: *RequestContext, wire: MoveTabType) !void {
    const moved = moveTab(request, .{
        .location = wire.location,
        .direction = wire.direction,
        .relative_to = wire.relative_to,
    }) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try moveTabQueueFailure(request, wire.request_id, .{
                .code = .workspace_not_found,
                .message = "workspace not found",
            }),
            error.TabNotFound => try moveTabQueueFailure(request, wire.request_id, .{
                .code = .tab_not_found,
                .message = "tab not found",
            }),
            else => return err,
        }

        return;
    };

    try request.session.delivery.responses.push(.{ .tab_moved = .{
        .request_id = wire.request_id,
        .location = moved.location,
        .position = moved.position,
    } });
}

fn prepareCreateTabLaunch(client: *RequestContext, request: CreateTabPrepareLaunch) ![]const u8 {
    if (!client.application.holdsGeometry(client.session.key, request.workspace)) {
        return error.GeometryUnavailable;
    }

    return launch_cwd_module.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .{ .workspace = request.workspace },
    ) catch error.InvalidLaunchCwd;
}

fn attachCreatedTab(client: *RequestContext, launched: CreateTabLaunchedPane) !void {
    const pane = client.application.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;

    _ = try client.session.attachments.attach(client.application.gpa, pane);
}

fn launchCreatedTabPane(application: *Application, request: CreateTabLaunchPane) !CreateTabLaunchedPane {
    const pane = try application.launchPane(.{
        .location = request.location,
        .kind = request.kind,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = request.launch_cwd,
        .workspace_path = request.workspace_path,
    });

    return .{ .id = pane.id, .pane_generation = pane.generation, .kind = pane.kind };
}

fn publishTabCreated(publication: *RequestContext, event: TabCreatedType) void {
    publication.application.noteSessionChange();
    publication.application.notifyWorkspaceChanged(publication.session.key, event.location.workspace);
}

fn publishTabRenamed(publication: *RequestContext, event: TabRenamedType) void {
    publication.application.noteSessionChange();

    publication.application.model.agents.touch();
    publication.application.notifyWorkspaceChanged(publication.session.key, event.location.workspace);
}

fn publishTabMoved(publication: *RequestContext, event: TabMovedType) void {
    publication.application.noteSessionChange();
    publication.application.notifyWorkspaceChanged(publication.session.key, event.location.workspace);
}

fn publishTabRemoved(publication: *RequestContext, event: TabRemovedType) void {
    publication.application.noteSessionChange();

    if (event.workspace_removed) {
        publication.application.notifyWorkspaceClosed(.{
            .origin = publication.session.key,
            .workspace = event.location.workspace,
            .previous_workspace = event.previous_workspace,
        });
    } else {
        publication.application.notifyWorkspaceChanged(publication.session.key, event.location.workspace);
    }
}

fn createTab(request: *RequestContext, command: CreateTab) anyerror!CreateTabResult {
    const application = request.application;

    const workspace = request.workspaces.find(command.workspace) orelse return error.WorkspaceNotFound;
    const launch_cwd = try prepareCreateTabLaunch(request, .{
        .workspace = command.workspace,
        .launch = command.launch,
    });
    const tab_id = try request.workspaces.nextTabId();
    const created = try workspace.createTab(tab_id, command.label);
    var committed = false;

    defer if (!committed) {
        const removed = workspace.removeTab(tab_id);
        std.debug.assert(removed);
    };

    const launched = launchCreatedTabPane(application, .{
        .location = created.location,
        .kind = command.kind,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = workspace.pathSlice(),
    }) catch |err| return create_tab.mapLaunchError(err);

    request.workspaces.recordTabCreated(tab_id);
    committed = true;
    publishTabCreated(request, created);
    try attachCreatedTab(request, launched);

    return .{
        .created = created,
        .root_pane_id = launched.id,
        .kind = launched.kind,
        .pane_generation = launched.pane_generation,
    };
}

fn createTabQueueFailure(request: *RequestContext, request_id: RequestIdType, failure: CreateTabFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn renameTab(request: *RequestContext, command: RenameTab) anyerror!TabRenamedType {
    const workspace = request.workspaces.find(command.location.workspace) orelse return error.TabNotFound;
    const renamed = try workspace.renameTab(command.location.tab_id, command.label);

    publishTabRenamed(request, renamed);
    return renamed;
}

fn renameTabQueueFailure(request: *RequestContext, request_id: RequestIdType, failure: RenameTabFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn moveTab(request: *RequestContext, command: MoveTab) anyerror!TabMovedType {
    const moved = try commands.moveTab(
        &request.workspaces,
        command.location,
        .{ .direction = command.direction, .relative_to = command.relative_to },
    );

    publishTabMoved(request, moved);
    return moved;
}

fn moveTabQueueFailure(request: *RequestContext, request_id: RequestIdType, failure: MoveTabFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn closeTab(request: *RequestContext, command: CloseTab) anyerror!TabRemovedType {
    const application = request.application;

    const removed = commands.removeTab(&request.workspaces, command.location) orelse return error.TabNotFound;

    application.model.panes.closeAt(removed.location);
    publishTabRemoved(request, removed);
    return removed;
}

fn closeTabQueueTabNotFound(request: *RequestContext, request_id: RequestIdType) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = .tab_not_found,
        .message = "tab not found",
    } });
}

fn requestTabSnapshot(request: *RequestContext, command: TabSnapshotRequest) anyerror!TabSnapshotResult {
    if (!(request.workspaces.reader().contains(command.location))) {
        return error.TabNotFound;
    }

    if ((request.application.model.panes.countAt(command.location)) == 0) {
        return error.TabNotFound;
    }

    return .{ .location = command.location };
}
