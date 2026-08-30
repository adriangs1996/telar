//! Tab lifecycle external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const attachment_mod = @import("../attachment.zig");
const pane_mod = @import("../../pane/root.zig");
const response_queue = @import("../response_queue.zig");
const workspace_mod = @import("../../workspace/root.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;
const PendingTabCreated = response_queue.PendingTabCreated;
const PendingTabRenamed = response_queue.PendingTabRenamed;
const WorkspaceRepository = workspace_mod.Repository;
const schema = core.schema;

pub const RequestTabSnapshotContext = struct {
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
};

pub const CreateTabContext = struct {
    gpa: std.mem.Allocator,
    workspaces: *WorkspaceRepository,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    events: common.WorkspaceEvents,
};

pub const RenameTabContext = struct {
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
    agents: *agent_mod.Tracker,
    client: common.ClientKey,
    events: common.WorkspaceEvents,
};

pub const CloseTabContext = struct {
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    events: common.WorkspaceEvents,
};

pub const MoveTabContext = struct {
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    events: common.WorkspaceEvents,
};

pub fn requestTabSnapshot(context: RequestTabSnapshotContext, request: schema.RequestTabSnapshot) !void {
    if (!context.workspaces.reader().contains(request.location) or context.panes.countAt(request.location) == 0) {
        try common.queueFailure(context.responses, request.request_id, .tab_not_found, "tab not found");
        return;
    }

    try context.responses.push(.{ .tab_snapshot = .{
        .request_id = request.request_id,
        .location = request.location,
    } });
}

/// Creates a tab and root pane as one rollback-safe runtime transaction. The
/// tab is removed again if pane launch fails before ownership is committed.
///
/// ```zig
/// try createTab(context, request);
/// ```
pub fn createTab(context: CreateTabContext, create: schema.CreateTabView) !void {
    const gpa = context.gpa;
    const workspaces = context.workspaces;
    const attachments = context.attachments;
    const responses = context.responses;
    const client = context.client;
    const shared_graphics = context.shared_graphics;
    const geometry = context.geometry;
    const launcher = context.launcher;
    const events = context.events;

    if (!geometry.holds(geometry.context, client, create.workspace)) {
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
        .{ .workspace = create.workspace },
    )) orelse return;

    const created = workspace_mod.createTab(
        workspaces,
        create.workspace,
        create.label,
    ) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try common.queueFailure(
                responses,
                create.request_id,
                .workspace_not_found,
                "workspace not found",
            ),
            error.TabLimitReached => try common.queueFailure(
                responses,
                create.request_id,
                .resource_limit,
                "tab limit reached",
            ),
            else => return err,
        }
        return;
    };

    var tab_committed = false;

    defer if (!tab_committed) {
        _ = workspace_mod.removeTab(workspaces, created.location);
    };

    const fresh = launcher.launch(
        launcher.context,
        created.location,
        create.size,
        create.launch,
        launch_cwd,
        workspaces.reader().workspacePath(create.workspace).?,
    ) catch |err| {
        try common.queueSpawnFailure(responses, create.request_id, err);
        return;
    };

    tab_committed = true;
    const attachment = try attachments.attach(gpa, fresh);
    attachment.configureGraphics(shared_graphics);
    const label = workspaces.reader().tabLabel(created.location).?;
    var pending: PendingTabCreated = .{
        .request_id = create.request_id,
        .location = created.location,
        .position = created.position,
        .label = undefined,
        .label_len = @intCast(label.len),
        .root_pane_id = fresh.id,
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try responses.push(.{ .tab_created = pending });
    events.changed(events.context, client, create.workspace);
}

/// Applies a tab rename, publishes its dependent agent projection and queues
/// the requesting client's confirmation only after the aggregate accepts it.
///
/// ```zig
/// try renameTab(context, rename);
/// ```
pub fn renameTab(context: RenameTabContext, rename: schema.RenameTab) !void {
    workspace_mod.renameTab(context.workspaces, rename.location, rename.label) catch |err| {
        switch (err) {
            error.TabNotFound => try common.queueFailure(context.responses, rename.request_id, .tab_not_found, "tab not found"),
            error.InvalidTabLabel => try common.queueFailure(context.responses, rename.request_id, .invalid_request, "invalid tab label"),
        }

        return;
    };

    const label = context.workspaces.reader().tabLabel(rename.location).?;
    context.agents.touch();
    var pending: PendingTabRenamed = .{
        .request_id = rename.request_id,
        .location = rename.location,
        .label = undefined,
        .label_len = @intCast(label.len),
    };
    @memcpy(pending.label[0..pending.label_len], label);
    try context.responses.push(.{ .tab_renamed = pending });
    context.events.changed(context.events.context, context.client, rename.location.workspace);
}

/// Closes every pane in a tab, removes the tab aggregate and reports which
/// workspace clients should focus if the final tab closed its workspace.
///
/// ```zig
/// try closeTab(context, request);
/// ```
pub fn closeTab(context: CloseTabContext, close: schema.CloseTab) !void {
    if (!context.workspaces.reader().contains(close.location)) {
        try common.queueFailure(context.responses, close.request_id, .tab_not_found, "tab not found");
        return;
    }

    context.panes.closeAt(close.location);
    const removal = workspace_mod.removeTab(context.workspaces, close.location).?;
    try context.responses.push(.{ .tab_closed = .{
        .request_id = close.request_id,
        .location = close.location,
        .workspace_closed = removal.workspace_closed,
        .previous_workspace = removal.previous_workspace,
    } });

    if (removal.workspace_closed) {
        context.events.closed(
            context.events.context,
            context.client,
            close.location.workspace,
            removal.previous_workspace,
        );
    } else {
        context.events.changed(context.events.context, context.client, close.location.workspace);
    }
}

/// Reorders one tab and publishes its new canonical position.
///
/// ```zig
/// try moveTab(context, request);
/// ```
pub fn moveTab(context: MoveTabContext, move: schema.MoveTab) !void {
    const position = workspace_mod.moveTab(context.workspaces, move.location, move.direction) catch |err| {
        switch (err) {
            error.WorkspaceNotFound => try common.queueFailure(context.responses, move.request_id, .workspace_not_found, "workspace not found"),
            error.TabNotFound => try common.queueFailure(context.responses, move.request_id, .tab_not_found, "tab not found"),
        }

        return;
    };

    try context.responses.push(.{ .tab_moved = .{
        .request_id = move.request_id,
        .location = move.location,
        .position = position,
    } });
    context.events.changed(context.events.context, context.client, move.location.workspace);
}

const TestWorkspaceEvents = struct {
    changed_count: usize = 0,
    closed_count: usize = 0,
    last_client: ?common.ClientKey = null,
    last_workspace: ?schema.WorkspaceLocation = null,

    fn capability(capture: *TestWorkspaceEvents) common.WorkspaceEvents {
        return .{
            .context = capture,
            .changed = changed,
            .closed = closed,
        };
    }

    fn changed(context: *anyopaque, client: common.ClientKey, workspace: schema.WorkspaceLocation) void {
        const capture: *TestWorkspaceEvents = @ptrCast(@alignCast(context));
        capture.changed_count += 1;
        capture.last_client = client;
        capture.last_workspace = workspace;
    }

    fn closed(context: *anyopaque, _: common.ClientKey, _: schema.WorkspaceLocation, _: ?schema.WorkspaceId) void {
        const capture: *TestWorkspaceEvents = @ptrCast(@alignCast(context));
        capture.closed_count += 1;
    }
};

test "renameTab commits aggregate state before publishing its effects" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var responses: common.ResponseQueue = .{};
    var agents: agent_mod.Tracker = .{};
    var events: TestWorkspaceEvents = .{};
    const client: common.ClientKey = .{ .id = 7, .generation = 3 };

    try renameTab(.{
        .workspaces = &workspaces,
        .responses = &responses,
        .agents = &agents,
        .client = client,
        .events = events.capability(),
    }, .{
        .request_id = @enumFromInt(11),
        .location = location,
        .label = "server",
    });

    try std.testing.expectEqualStrings("server", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(@as(u64, 2), agents.revision);
    try std.testing.expectEqual(@as(usize, 1), events.changed_count);
    try std.testing.expectEqualDeep(client, events.last_client.?);
    try std.testing.expectEqualDeep(location.workspace, events.last_workspace.?);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .tab_renamed);
    try std.testing.expectEqualStrings("server", response.tab_renamed.labelSlice());
}

test "renameTab rejection queues a failure without publishing side effects" {
    var state: workspace_mod.State = .{};
    var workspaces = WorkspaceRepository.init(&state, std.testing.allocator);
    defer workspaces.deinit();
    const location = (try workspaces.ensure("/work/project")).location;
    var responses: common.ResponseQueue = .{};
    var agents: agent_mod.Tracker = .{};
    var events: TestWorkspaceEvents = .{};

    var missing = location;
    missing.tab_id = try schema.id.tab(999);
    try renameTab(.{
        .workspaces = &workspaces,
        .responses = &responses,
        .agents = &agents,
        .client = .{ .id = 7, .generation = 3 },
        .events = events.capability(),
    }, .{
        .request_id = @enumFromInt(12),
        .location = missing,
        .label = "server",
    });

    try std.testing.expectEqualStrings("main", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(@as(u64, 1), agents.revision);
    try std.testing.expectEqual(@as(usize, 0), events.changed_count);
    const response = responses.peek().?;
    try std.testing.expect(response.* == .request_failed);
    try std.testing.expectEqual(schema.FailureCode.tab_not_found, response.request_failed.code);

    responses.pop();
    try renameTab(.{
        .workspaces = &workspaces,
        .responses = &responses,
        .agents = &agents,
        .client = .{ .id = 7, .generation = 3 },
        .events = events.capability(),
    }, .{
        .request_id = @enumFromInt(13),
        .location = location,
        .label = "",
    });

    try std.testing.expectEqualStrings("main", workspaces.reader().tabLabel(location).?);
    try std.testing.expectEqual(@as(u64, 1), agents.revision);
    try std.testing.expectEqual(@as(usize, 0), events.changed_count);
    const invalid_response = responses.peek().?;
    try std.testing.expect(invalid_response.* == .request_failed);
    try std.testing.expectEqual(schema.FailureCode.invalid_request, invalid_response.request_failed.code);
}
