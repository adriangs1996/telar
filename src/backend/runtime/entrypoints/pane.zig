//! Pane attach, launch, and close external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;
const WorkspaceRepository = workspace_mod.Repository;
const schema = core.schema;

pub const OpenPaneContext = struct {
    gpa: std.mem.Allocator,
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    scheduler: common.Scheduler,
};

pub const CreatePaneContext = struct {
    gpa: std.mem.Allocator,
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    events: common.WorkspaceEvents,
};

/// Resolves an existing target or launches the default pane, then attaches it
/// to the requesting client only after runtime ownership succeeds.
///
/// ```zig
/// try openPane(context, request);
/// ```
pub fn openPane(context: OpenPaneContext, open: schema.OpenPaneView) !void {
    const gpa = context.gpa;
    const panes = context.panes;
    const workspaces = context.workspaces;
    const attachments = context.attachments;
    const responses = context.responses;
    const client = context.client;
    const shared_graphics = context.shared_graphics;
    const geometry = context.geometry;
    const launcher = context.launcher;
    const scheduler = context.scheduler;

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
            const workspace_location: schema.WorkspaceLocation = .{ .workspace = wanted };
            const default_tab = workspaces.reader().defaultTab(workspace_location) orelse {
                try common.queueFailure(
                    responses,
                    open.request_id,
                    .workspace_not_found,
                    "workspace not found",
                );
                return;
            };
            const location: schema.TabLocation = .{
                .workspace = workspace_location,
                .tab_id = default_tab,
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
                const removed = workspaces.remove(workspace_id);
                std.debug.assert(removed);
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
            const workspace_path = workspaces.reader().workspacePath(location.workspace).?;
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

/// Launches a sibling pane inside an existing tab and publishes the committed
/// workspace change after the requesting client is attached.
///
/// ```zig
/// try createPane(context, request);
/// ```
pub fn createPane(context: CreatePaneContext, create: schema.CreatePaneView) !void {
    const gpa = context.gpa;
    const panes = context.panes;
    const workspaces = context.workspaces;
    const attachments = context.attachments;
    const responses = context.responses;
    const client = context.client;
    const shared_graphics = context.shared_graphics;
    const geometry = context.geometry;
    const launcher = context.launcher;
    const events = context.events;

    if (!workspaces.reader().contains(create.location) or panes.countAt(create.location) == 0) {
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
    const workspace_path = workspaces.reader().workspacePath(create.location.workspace).?;
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
