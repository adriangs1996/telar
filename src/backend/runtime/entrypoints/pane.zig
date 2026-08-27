//! Pane attach, launch, and close external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../workspace.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;
const WorkspaceStore = workspace_mod.WorkspaceStore;
const schema = core.schema;

pub fn openPane(
    gpa: std.mem.Allocator,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    scheduler: common.Scheduler,
    open: schema.OpenPaneView,
) !void {
    var created = false;
    const active = switch (open.target) {
        .pane => |wanted| pane: {
            const existing = panes.findRunning(wanted) orelse {
                try common.queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                return;
            };
            if (existing.close_requested or existing.exit != null) {
                try common.queueFailure(responses, open.request_id, .pane_not_found, "pane not found");
                return;
            }
            break :pane existing;
        },
        .workspace => |wanted| pane: {
            const workspace = workspaces.find(.{ .workspace = wanted }) orelse {
                try common.queueFailure(
                    responses,
                    open.request_id,
                    .workspace_not_found,
                    "workspace not found",
                );
                return;
            };
            const location: schema.TabLocation = .{
                .workspace = .{ .workspace = wanted },
                .tab_id = workspace.defaultTab(),
            };
            const existing = panes.firstAt(location) orelse {
                try common.queueFailure(
                    responses,
                    open.request_id,
                    .pane_not_found,
                    "workspace has no running pane",
                );
                return;
            };
            break :pane existing;
        },
        .default => pane: {
            const launch = open.launch.?;
            const launch_cwd = (try common.requestLaunchCwd(
                attachments,
                responses,
                open.request_id,
                launch,
                .any,
            )) orelse return;
            const ensured = workspaces.ensure(launch_cwd) catch {
                try common.queueFailure(
                    responses,
                    open.request_id,
                    .resource_limit,
                    "could not create workspace",
                );
                return;
            };
            var workspace_committed = !ensured.created;
            const workspace_id = switch (ensured.location.workspace) {
                .workspace => |id| id,
                .worktree => unreachable,
            };
            defer if (!workspace_committed) {
                workspaces.remove(workspace_id);
                geometry.release(geometry.context, client, ensured.location.workspace);
            };
            const location = ensured.location;
            if (panes.firstAt(location)) |existing| break :pane existing;
            if (!geometry.holds(geometry.context, client, location.workspace)) {
                try common.queueFailure(
                    responses,
                    open.request_id,
                    .resource_limit,
                    "workspace geometry is leased by another client",
                );
                return;
            }
            const workspace_path = workspaces.find(location.workspace).?.path;
            const fresh = launcher.launch(
                launcher.context,
                location,
                open.size,
                launch,
                launch_cwd,
                workspace_path,
            ) catch |err| {
                try common.queueSpawnFailure(responses, open.request_id, err);
                return;
            };
            workspace_committed = true;
            created = true;
            break :pane fresh;
        },
    };

    if (geometry.holds(geometry.context, client, active.location.workspace)) {
        const resize_result = if (active.ingest_pending)
            active.requestResize(open.size)
        else
            active.resize(open.size);
        resize_result catch {
            try common.queueFailure(responses, open.request_id, .internal, "could not resize pane");
            return;
        };
        try scheduler.observation(scheduler.context, active);
        try scheduler.media(scheduler.context, active);
    }
    const attachment = try attachments.attach(gpa, active);
    attachment.configureGraphics(shared_graphics);
    _ = try attachment.resizeIfNeeded();
    try responses.push(.{ .pane_opened = .{
        .request_id = open.request_id,
        .pane_id = active.id,
        .location = active.location,
        .created = created,
    } });
}

pub fn createPane(
    gpa: std.mem.Allocator,
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    events: common.WorkspaceEvents,
    create: schema.CreatePaneView,
) !void {
    if (!workspaces.contains(create.location) or panes.countAt(create.location) == 0) {
        try common.queueFailure(responses, create.request_id, .pane_not_found, "tab not found");
        return;
    }
    if (!geometry.holds(geometry.context, client, create.location.workspace)) {
        try common.queueFailure(
            responses,
            create.request_id,
            .resource_limit,
            "workspace geometry is leased by another client",
        );
        return;
    }
    const launch_cwd = (try common.requestLaunchCwd(
        attachments,
        responses,
        create.request_id,
        create.launch,
        .{ .tab = create.location },
    )) orelse return;
    const workspace_path = workspaces.find(create.location.workspace).?.path;
    const fresh = launcher.launch(
        launcher.context,
        create.location,
        create.size,
        create.launch,
        launch_cwd,
        workspace_path,
    ) catch |err| {
        try common.queueSpawnFailure(responses, create.request_id, err);
        return;
    };
    const attachment = try attachments.attach(gpa, fresh);
    attachment.configureGraphics(shared_graphics);
    try responses.push(.{ .pane_opened = .{
        .request_id = create.request_id,
        .pane_id = fresh.id,
        .location = fresh.location,
        .created = true,
    } });
    events.changed(events.context, client, create.location.workspace);
}

pub fn closePane(
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    close: schema.ClosePane,
) !void {
    const active = attachments.find(close.pane_id) orelse {
        try common.queueFailure(responses, close.request_id, .pane_not_found, "pane not attached");
        return;
    };
    if (!active.pane.close_requested) {
        active.pane.close_requested = true;
        active.pane.session.shutdown();
    }
}
