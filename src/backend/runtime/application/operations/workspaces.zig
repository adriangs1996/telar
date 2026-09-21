//! Runtime workspaces operations, reached from requests.dispatch.

const Application = @import("../Application.zig");
const CreateWorkspace = @import("../commands/CreateWorkspace.zig");
const CreateWorkspaceResult = @import("../commands/CreateWorkspaceResult.zig");
const create_workspace = @import("../commands/create_workspace.zig");
const CreateWorkspaceFailure = @import("../../entrypoints/requests/CreateWorkspaceFailure.zig");
const RenameWorkspace = @import("../commands/RenameWorkspace.zig");
const commands = @import("../../../workspace/commands.zig");
const RenameWorkspaceFailure = @import("../../entrypoints/requests/RenameWorkspaceFailure.zig");
const WorkspaceSnapshotRequest = @import("../queries/WorkspaceSnapshotRequest.zig");
const WorkspaceSnapshotResult = @import("../queries/WorkspaceSnapshotResult.zig");
const RequestIdType = @import("telar-core").RequestId;
const RequestWorkspaceSnapshotType = @import("telar-core").RequestWorkspaceSnapshot;
const CreateWorkspaceViewType = @import("telar-core").CreateWorkspaceView;
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const launch_cwd_module = @import("../../client/launch_cwd.zig");
const CreateWorkspacePrepareLaunch = @import("../commands/CreateWorkspacePrepareLaunch.zig");
const CreateWorkspaceLaunchPane = @import("../commands/CreateWorkspaceLaunchPane.zig");
const CreateWorkspaceLaunchedPane = @import("../commands/CreateWorkspaceLaunchedPane.zig");
const WorkspaceRenamedType = @import("../../../workspace/WorkspaceRenamed.zig");
const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try workspaces.routeRequestWorkspaceSnapshot(request, wire);`.
pub fn routeRequestWorkspaceSnapshot(request: *RequestContext, wire: RequestWorkspaceSnapshotType) !void {
    const snapshot = requestWorkspaceSnapshot(request, .{ .location = wire.workspace }) catch |err| {
        if (err == error.WorkspaceNotFound) {
            try request.session.delivery.responses.push(.{ .request_failed = .{
                .request_id = wire.request_id,
                .code = .workspace_not_found,
                .message = "workspace not found",
            } });
            return;
        }

        return err;
    };

    try request.session.delivery.responses.push(.{ .workspace_snapshot = .{
        .request_id = wire.request_id,
        .workspace = snapshot.location,
    } });
}

/// Example: `try workspaces.routeCreateWorkspace(request, wire);`.
pub fn routeCreateWorkspace(request: *RequestContext, wire: CreateWorkspaceViewType) !void {
    const result = createWorkspace(request, .{
        .name = wire.name,
        .size = wire.size,
        .launch = wire.launch,
        .create_cwd = wire.create_cwd,
    }) catch |err| {
        const failure: CreateWorkspaceFailure = switch (err) {
            error.InvalidLaunchCwd => .{ .code = .invalid_request, .message = "cwd source pane is unavailable" },
            error.LaunchCwdCreateFailed => .{ .code = .spawn_failed, .message = "could not create the working directory" },
            error.WorkspaceCreateFailed => .{ .code = .resource_limit, .message = "could not create workspace" },
            error.GeometryUnavailable => .{ .code = .resource_limit, .message = "workspace geometry is unavailable" },
            error.PaneLimitReached => .{ .code = .resource_limit, .message = "pane limit reached" },
            error.UnsupportedEnvironment => .{ .code = .invalid_request, .message = "custom pane environment is not supported" },
            error.PaneSpawnFailed => .{ .code = .spawn_failed, .message = "could not start pane process" },
            else => return err,
        };

        try createWorkspaceQueueFailure(request, wire.request_id, failure);
        return;
    };

    try request.session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = wire.request_id,
        .pane_id = result.root_pane_id,
        .location = result.created.location,
        .created = true,
    } });
}

/// Example: `try workspaces.routeRenameWorkspace(request, wire);`.
pub fn routeRenameWorkspace(request: *RequestContext, wire: RenameWorkspaceType) !void {
    const renamed = renameWorkspace(request, .{
        .location = wire.workspace,
        .name = wire.name,
    }) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try renameWorkspaceQueueFailure(request, wire.request_id, .{
                .code = .workspace_not_found,
                .message = "workspace not found",
            }),
            error.InvalidWorkspaceName => try renameWorkspaceQueueFailure(request, wire.request_id, .{
                .code = .internal,
                .message = "could not rename workspace",
            }),
            else => return err,
        }

        return;
    };

    try request.session.delivery.responses.push(.{ .workspace_snapshot = .{
        .request_id = wire.request_id,
        .workspace = renamed.location,
    } });
}

fn prepareCreateWorkspaceLaunch(client: *RequestContext, request: CreateWorkspacePrepareLaunch) ![]const u8 {
    const cwd = launch_cwd_module.resolveLaunchCwd(
        &client.session.attachments,
        request.launch,
        .any,
    ) catch return error.InvalidLaunchCwd;
    if (request.create_cwd and request.launch.cwd_source == null) {
        launch_cwd_module.createLaunchDirectory(client.application.io, cwd) catch return error.LaunchCwdCreateFailed;
    }

    return cwd;
}

fn launchCreatedWorkspacePane(application: *Application, request: CreateWorkspaceLaunchPane) !CreateWorkspaceLaunchedPane {
    const pane = try application.launchPane(.{
        .location = request.location,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = request.launch_cwd,
        .workspace_path = request.workspace_path,
    });

    return .{ .id = pane.id };
}

fn replaceCreatedWorkspaceAttachments(client: *RequestContext, launched: CreateWorkspaceLaunchedPane) !void {
    const pane = client.application.model.panes.findRunning(launched.id) orelse return error.LaunchedPaneUnavailable;
    const previous_workspace = client.session.attachments.currentWorkspace();

    client.session.attachments.clearAttachments();
    if (previous_workspace) |previous| {
        client.application.releaseGeometryFor(client.session.key, previous);
    }

    const attachment = try client.session.attachments.attach(client.application.gpa, pane);
    _ = try attachment.resizeIfNeeded();
}

fn publishWorkspaceRenamed(publication: *RequestContext, event: WorkspaceRenamedType) void {
    publication.application.noteSessionChange();

    publication.application.model.agents.touch();
    publication.application.notifyWorkspaceChanged(publication.session.key, event.location);
}

fn publishWorkspaceCreated(publication: *RequestContext, event: WorkspaceCreatedType) void {
    publication.application.noteSessionChange();
    publication.application.notifyWorkspaceChanged(publication.session.key, event.location.workspace);
}

fn createWorkspace(request: *RequestContext, command: CreateWorkspace) anyerror!CreateWorkspaceResult {
    const application = request.application;

    const launch_cwd = try prepareCreateWorkspaceLaunch(request, .{
        .launch = command.launch,
        .create_cwd = command.create_cwd,
    });
    var proposal = request.workspaces.propose(.{
        .path = launch_cwd,
        .explicit_name = command.name,
    }) catch return error.WorkspaceCreateFailed;
    defer proposal.rollback();

    const location = proposal.location();
    var lease_acquired = false;
    var committed = false;
    defer if (!committed and lease_acquired) {
        request.application.releaseGeometryFor(request.session.key, location.workspace);
    };

    if (!request.application.holdsGeometry(request.session.key, location.workspace)) {
        return error.GeometryUnavailable;
    }
    lease_acquired = true;

    const launched = launchCreatedWorkspacePane(application, .{
        .location = location,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = proposal.path(),
    }) catch |err| return create_workspace.mapLaunchError(err);
    const created = WorkspaceCreatedType.init(location, proposal.name()) catch unreachable;

    _ = proposal.commit();
    committed = true;
    publishWorkspaceCreated(request, created);
    try replaceCreatedWorkspaceAttachments(request, launched);

    return .{
        .created = created,
        .root_pane_id = launched.id,
    };
}

fn createWorkspaceQueueFailure(request: *RequestContext, request_id: RequestIdType, failure: CreateWorkspaceFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn renameWorkspace(request: *RequestContext, command: RenameWorkspace) anyerror!WorkspaceRenamedType {
    const renamed = try commands.renameWorkspace(
        &request.workspaces,
        command.location,
        command.name,
    );

    publishWorkspaceRenamed(request, renamed);
    return renamed;
}

fn renameWorkspaceQueueFailure(request: *RequestContext, request_id: RequestIdType, failure: RenameWorkspaceFailure) !void {
    try request.session.delivery.responses.push(.{ .request_failed = .{
        .request_id = request_id,
        .code = failure.code,
        .message = failure.message,
    } });
}

fn requestWorkspaceSnapshot(request: *RequestContext, command: WorkspaceSnapshotRequest) anyerror!WorkspaceSnapshotResult {
    if (!(request.workspaces.reader()).containsWorkspace(command.location)) {
        return error.WorkspaceNotFound;
    }

    return .{ .location = command.location };
}
