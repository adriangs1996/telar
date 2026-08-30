//! Tab lifecycle external message entrypoints.

const core = @import("telar-core");
const pane_mod = @import("../../pane/root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const common = @import("common.zig");

const PaneStore = pane_mod.PaneStore;
const WorkspaceRepository = workspace_mod.Repository;
const schema = core.schema;

pub const RequestTabSnapshotContext = struct {
    panes: *PaneStore,
    workspaces: *WorkspaceRepository,
    responses: *common.ResponseQueue,
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
