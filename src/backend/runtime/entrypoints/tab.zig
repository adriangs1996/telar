//! Tab lifecycle external message entrypoints.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const attachment_mod = @import("../attachment.zig");
const pane_mod = @import("../../pane/root.zig");
const response_queue = @import("../response_queue.zig");
const workspace_mod = @import("../workspace.zig");
const common = @import("common.zig");

const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;
const PendingTabCreated = response_queue.PendingTabCreated;
const PendingTabRenamed = response_queue.PendingTabRenamed;
const WorkspaceStore = workspace_mod.WorkspaceStore;
const schema = core.schema;

pub fn requestTabSnapshot(panes: *PaneStore, workspaces: *WorkspaceStore, responses: *common.ResponseQueue, request: schema.RequestTabSnapshot) !void {
    if (!workspaces.contains(request.location) or panes.countAt(request.location) == 0) {
        try common.queueFailure(responses, request.request_id, .tab_not_found, "tab not found");
        return;
    }
    try responses.push(.{ .tab_snapshot = .{
        .request_id = request.request_id,
        .location = request.location,
    } });
}

pub fn createTab(
    gpa: std.mem.Allocator,
    workspaces: *WorkspaceStore,
    attachments: *AttachmentStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    shared_graphics: bool,
    geometry: common.Geometry,
    launcher: common.Launcher,
    events: common.WorkspaceEvents,
    create: schema.CreateTabView,
) !void {
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
    var generated_label: [schema.max_tab_label_bytes]u8 = undefined;
    const created = workspaces.createTab(
        create.workspace,
        create.label,
        &generated_label,
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
        _ = workspaces.removeTab(created.location);
    };
    const fresh = launcher.launch(
        launcher.context,
        created.location,
        create.size,
        create.launch,
        launch_cwd,
        workspaces.find(create.workspace).?.path,
    ) catch |err| {
        try common.queueSpawnFailure(responses, create.request_id, err);
        return;
    };
    tab_committed = true;
    const attachment = try attachments.attach(gpa, fresh);
    attachment.configureGraphics(shared_graphics);
    const tab = workspaces.findTab(created.location).?;
    var pending: PendingTabCreated = .{
        .request_id = create.request_id,
        .location = created.location,
        .position = created.position,
        .label = undefined,
        .label_len = @intCast(tab.labelSlice().len),
        .root_pane_id = fresh.id,
    };
    @memcpy(pending.label[0..pending.label_len], tab.labelSlice());
    try responses.push(.{ .tab_created = pending });
    events.changed(events.context, client, create.workspace);
}

pub fn renameTab(workspaces: *WorkspaceStore, responses: *common.ResponseQueue, agents: *agent_mod.Registry, client: common.ClientKey, events: common.WorkspaceEvents, rename: schema.RenameTab) !void {
    const tab = workspaces.findTab(rename.location) orelse {
        try common.queueFailure(responses, rename.request_id, .tab_not_found, "tab not found");
        return;
    };
    tab.setLabel(rename.label);
    agents.touch();
    var pending: PendingTabRenamed = .{
        .request_id = rename.request_id,
        .location = rename.location,
        .label = undefined,
        .label_len = @intCast(rename.label.len),
    };
    @memcpy(pending.label[0..pending.label_len], rename.label);
    try responses.push(.{ .tab_renamed = pending });
    events.changed(events.context, client, rename.location.workspace);
}

pub fn closeTab(
    panes: *PaneStore,
    workspaces: *WorkspaceStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    events: common.WorkspaceEvents,
    close: schema.CloseTab,
) !void {
    if (!workspaces.contains(close.location)) {
        try common.queueFailure(responses, close.request_id, .tab_not_found, "tab not found");
        return;
    }
    panes.closeAt(close.location);
    const removal = workspaces.removeTab(close.location).?;
    try responses.push(.{ .tab_closed = .{
        .request_id = close.request_id,
        .location = close.location,
        .workspace_closed = removal.workspace_closed,
        .previous_workspace = removal.previous_workspace,
    } });
    if (removal.workspace_closed) {
        events.closed(
            events.context,
            client,
            close.location.workspace,
            removal.previous_workspace,
        );
    } else {
        events.changed(events.context, client, close.location.workspace);
    }
}

pub fn moveTab(
    workspaces: *WorkspaceStore,
    responses: *common.ResponseQueue,
    client: common.ClientKey,
    events: common.WorkspaceEvents,
    move: schema.MoveTab,
) !void {
    const workspace = workspaces.find(move.location.workspace) orelse {
        try common.queueFailure(
            responses,
            move.request_id,
            .workspace_not_found,
            "workspace not found",
        );
        return;
    };
    const position = workspace.moveTab(move.location.tab_id, move.direction) orelse {
        try common.queueFailure(responses, move.request_id, .tab_not_found, "tab not found");
        return;
    };
    try responses.push(.{ .tab_moved = .{
        .request_id = move.request_id,
        .location = move.location,
        .position = position,
    } });
    events.changed(events.context, client, move.location.workspace);
}
