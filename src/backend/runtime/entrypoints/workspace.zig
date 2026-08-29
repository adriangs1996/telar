//! Workspace lifecycle external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const attachment_mod = @import("../attachment.zig");
const workspace_mod = @import("../workspace.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const WorkspaceStore = workspace_mod.WorkspaceStore;
const schema = core.schema;

pub fn createWorkspace(
    gpa: std.mem.Allocator,
    workspaces: *WorkspaceStore,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    create: schema.CreateWorkspaceView,
) !void {
    const launch_cwd = (try common.requestLaunchCwd(
        attachments,
        responses,
        create.request_id,
        create.launch,
        .any,
    )) orelse return;
    const location = workspaces.create(launch_cwd, create.name) catch {
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
        workspaces.remove(workspace_id);
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

pub fn renameWorkspace(workspaces: *WorkspaceStore, responses: *common.ResponseQueue, agents: *agent_mod.Registry, client: common.ClientKey, events: common.WorkspaceEvents, rename: schema.RenameWorkspace) !void {
    workspaces.rename(rename.workspace, rename.name) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try common.queueFailure(
                responses,
                rename.request_id,
                .workspace_not_found,
                "workspace not found",
            ),
            else => try common.queueFailure(
                responses,
                rename.request_id,
                .internal,
                "could not rename workspace",
            ),
        }
        return;
    };
    agents.touch();
    try responses.push(.{ .workspace_snapshot = .{
        .request_id = rename.request_id,
        .workspace = rename.workspace,
    } });
    events.changed(events.context, client, rename.workspace);
}

pub fn requestWorkspaceSnapshot(
    workspaces: *WorkspaceStore,
    responses: *common.ResponseQueue,
    request: schema.RequestWorkspaceSnapshot,
) !void {
    if (workspaces.find(request.workspace) == null) {
        try common.queueFailure(
            responses,
            request.request_id,
            .workspace_not_found,
            "workspace not found",
        );
        return;
    }
    try responses.push(.{ .workspace_snapshot = .{
        .request_id = request.request_id,
        .workspace = request.workspace,
    } });
}
