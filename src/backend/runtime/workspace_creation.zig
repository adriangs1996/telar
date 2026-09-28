//! A client creates a workspace: the runtime proposes it, takes its
//! geometry lease, launches the root pane and commits the workspace only
//! after the pane launch commits.

const session_checkpoint = @import("session_checkpoint.zig");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const launch_cwd = @import("client/launch_cwd.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_launch = @import("pane_launch.zig");
const resync_required = @import("resync_required.zig");

/// Creates the workspace and moves the client's attachments to its root pane.
///
/// ```zig
/// try workspace_creation.create(model, session, request);
/// ```
pub fn create(model: *RuntimeModel, session: *Session, request: core.CreateWorkspaceView) !void {
    const pane = createWorkspace(model, session, request) catch |err| {
        return switch (err) {
            error.InvalidLaunchCwd => client_request.fail(session, request.request_id, .invalid_request, "cwd source pane is unavailable"),
            error.LaunchCwdCreateFailed => client_request.fail(session, request.request_id, .spawn_failed, "could not create the working directory"),
            error.WorkspaceCreateFailed => client_request.fail(session, request.request_id, .resource_limit, "could not create workspace"),
            error.GeometryUnavailable => client_request.fail(session, request.request_id, .resource_limit, "workspace geometry is unavailable"),
            error.PaneLimitReached => client_request.fail(session, request.request_id, .resource_limit, "pane limit reached"),
            error.UnsupportedEnvironment => client_request.fail(session, request.request_id, .invalid_request, "custom pane environment is not supported"),
            else => if (pane_launch.spawnFailure(err)) |reason| client_request.fail(session, request.request_id, .spawn_failed, reason) else err,
        };
    };

    try session.delivery.responses.push(.{ .pane_opened = .{
        .request_id = request.request_id,
        .pane_id = pane.id,
        .location = pane.location,
        .created = true,
    } });
}

fn createWorkspace(model: *RuntimeModel, session: *Session, request: core.CreateWorkspaceView) !*Pane {
    const cwd = launch_cwd.resolveLaunchCwd(model, session, request.launch, .any) catch return error.InvalidLaunchCwd;
    if (request.create_cwd and request.launch.cwd_source == null) {
        launch_cwd.createLaunchDirectory(model.io, cwd) catch return error.LaunchCwdCreateFailed;
    }

    const proposal = model.workspaces.propose(model.gpa, cwd, request.name) catch return error.WorkspaceCreateFailed;
    defer model.workspaces.rollback(model.gpa, proposal);

    const location: core.TabLocation = .{
        .workspace = .{ .workspace = model.workspaces.id[proposal] },
        .tab_id = model.workspaces.tab_id[proposal][0],
    };
    var lease_acquired = false;
    var committed = false;
    defer if (!committed and lease_acquired) {
        geometry_lease.release(model, session.key, location.workspace);
    };

    if (!geometry_lease.acquire(model, session.key, location.workspace)) {
        return error.GeometryUnavailable;
    }
    lease_acquired = true;

    const launched = pane_launch.launch(model, .{
        .location = location,
        .size = request.size,
        .launch = request.launch,
        .launch_cwd = cwd,
        .workspace_path = model.workspaces.path[proposal],
    }) catch |err| return pane_launch.requestError(err);
    const root_pane_id = launched.id;

    _ = model.workspaces.commit(proposal);
    committed = true;
    session_checkpoint.noteChange(model);
    resync_required.notify(model, .{ .origin = session.key, .workspace = location.workspace });

    const pane = model.panes.findRunning(root_pane_id) orelse return error.LaunchedPaneUnavailable;
    const previous_workspace = session.workspace;
    pane_attachment.clear(model, session);
    if (previous_workspace) |previous| {
        geometry_lease.release(model, session.key, previous);
    }

    const attachment = try pane_attachment.attach(model, session, pane);
    _ = try attachment.resizeIfNeeded();
    return pane;
}
