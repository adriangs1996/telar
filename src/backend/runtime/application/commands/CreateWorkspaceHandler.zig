const Repository = @import("../../../workspace/Repository.zig");
const CreateWorkspaceLaunchAuthority = @import("CreateWorkspaceLaunchAuthority.zig");
const CreateWorkspaceGeometryLease = @import("CreateWorkspaceGeometryLease.zig");
const CreateWorkspacePaneLauncher = @import("CreateWorkspacePaneLauncher.zig");
const ClientAttachment = @import("ClientAttachment.zig");
const CreateWorkspaceEventPublisher = @import("CreateWorkspaceEventPublisher.zig");
const CreateWorkspace = @import("CreateWorkspace.zig");
const CreateWorkspaceResult = @import("CreateWorkspaceResult.zig");
const create_workspace = @import("create_workspace.zig");
const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const CreateWorkspaceExecutor = @import("CreateWorkspaceExecutor.zig");
const CreateWorkspaceHandler = @This();

workspaces: *Repository,
authority: CreateWorkspaceLaunchAuthority,
geometry: CreateWorkspaceGeometryLease,
launcher: CreateWorkspacePaneLauncher,
attachment: ClientAttachment,
events: CreateWorkspaceEventPublisher,

/// Creates an invisible workspace proposal, acquires its geometry lease,
/// launches the root pane, then commits and publishes the aggregate before
/// replacing client attachments. Pre-commit failures release all proposed
/// state; post-commit failures preserve runtime state.
///
/// ```zig
/// const result = try handler.execute(command);
/// ```
pub fn execute(handler: *CreateWorkspaceHandler, command: CreateWorkspace) !CreateWorkspaceResult {
    const launch_cwd = try handler.authority.prepare(handler.authority.context, .{
        .launch = command.launch,
    });
    var proposal = handler.workspaces.propose(.{
        .path = launch_cwd,
        .explicit_name = command.name,
    }) catch return error.WorkspaceCreateFailed;
    defer proposal.rollback();

    const location = proposal.location();
    var lease_acquired = false;
    var committed = false;
    defer if (!committed and lease_acquired) {
        handler.geometry.release(handler.geometry.context, location.workspace);
    };

    if (!handler.geometry.acquire(handler.geometry.context, location.workspace)) {
        return error.GeometryUnavailable;
    }
    lease_acquired = true;

    const launched = handler.launcher.launch(handler.launcher.context, .{
        .location = location,
        .size = command.size,
        .launch = command.launch,
        .launch_cwd = launch_cwd,
        .workspace_path = proposal.path(),
    }) catch |err| return create_workspace.mapLaunchError(err);
    const created = WorkspaceCreatedType.init(location, proposal.name()) catch unreachable;

    _ = proposal.commit();
    committed = true;
    handler.events.publish(handler.events.context, created);
    try handler.attachment.replace(handler.attachment.context, launched);

    return .{
        .created = created,
        .root_pane_id = launched.id,
    };
}

/// Exposes this handler through the command interface used by controllers.
///
/// ```zig
/// const executor = handler.executor();
/// ```
pub fn executor(handler: *CreateWorkspaceHandler) CreateWorkspaceExecutor {
    return .{ .context = handler, .execute_fn = executeErased };
}

fn executeErased(context: *anyopaque, command: CreateWorkspace) !CreateWorkspaceResult {
    const handler: *CreateWorkspaceHandler = @ptrCast(@alignCast(context));
    return handler.execute(command);
}
