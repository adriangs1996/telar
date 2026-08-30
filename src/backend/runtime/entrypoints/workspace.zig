//! Workspace lifecycle external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const workspace_mod = @import("../../workspace/root.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const WorkspaceRepository = workspace_mod.Repository;
const schema = core.schema;

pub const CreateWorkspaceContext = struct {
    gpa: std.mem.Allocator,
    workspaces: *WorkspaceRepository,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
};

/// Creates the workspace aggregate and its root pane as one rollback-safe
/// runtime transaction, then attaches the requesting client.
///
/// ```zig
/// try createWorkspace(context, request);
/// ```
pub fn createWorkspace(context: CreateWorkspaceContext, create: schema.CreateWorkspaceView) !void {
    const gpa = context.gpa;
    const workspaces = context.workspaces;
    const attachments = context.attachments;
    const responses = context.responses;
    const client = context.client;
    const shared_graphics = context.shared_graphics;
    const geometry = context.geometry;
    const launcher = context.launcher;

    const launch_cwd = (try common.requestLaunchCwd(
        attachments,
        responses,
        create.request_id,
        create.launch,
        .any,
    )) orelse return;
    const location = workspaces.insert(.{
        .path = launch_cwd,
        .explicit_name = create.name,
    }) catch {
        try common.queueFailure(
            responses,
            create.request_id,
            .resource_limit,
            "could not create workspace",
        );
        return;
    };
    const workspace_id = switch (location.workspace) {
        .workspace => |id| id,
        .worktree => unreachable,
    };
    var workspace_committed = false;
    defer if (!workspace_committed) {
        const removed = workspaces.remove(workspace_id);
        std.debug.assert(removed);
        geometry.release(geometry.context, client, location.workspace);
    };
    if (!geometry.holds(geometry.context, client, location.workspace)) {
        try common.queueFailure(
            responses,
            create.request_id,
            .resource_limit,
            "workspace geometry is unavailable",
        );
        return;
    }
    const fresh = launcher.launch(
        launcher.context,
        location,
        create.size,
        create.launch,
        launch_cwd,
        launch_cwd,
    ) catch |err| {
        try common.queueSpawnFailure(responses, create.request_id, err);
        return;
    };
    workspace_committed = true;
    const previous_workspace = attachments.currentWorkspace();
    attachments.deinit();
    if (previous_workspace) |previous|
        geometry.release(geometry.context, client, previous);
    const attachment = try attachments.attach(gpa, fresh);
    attachment.configureGraphics(shared_graphics);
    _ = try attachment.resizeIfNeeded();
    try responses.push(.{ .pane_opened = .{
        .request_id = create.request_id,
        .pane_id = fresh.id,
        .location = fresh.location,
        .created = true,
    } });
}
