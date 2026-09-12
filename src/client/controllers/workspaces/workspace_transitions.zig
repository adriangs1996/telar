//! Adapts committed workspace transitions to navigation and client ports.

const Client = @import("../../AttachedClient.zig");
const OpenedPaneType = @import("../../application/panes/OpenedPane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const WorkspaceArrivalType = @import("../../model/WorkspaceArrival.zig");
const PlanWorkspaceArrivalHandlerType = @import("../../application/workspaces/PlanWorkspaceArrivalHandler.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const BookmarkType = @import("../../application/workspaces/Bookmark.zig");
const WorkspaceDepartureType = @import("../../model/WorkspaceDeparture.zig");
const ReleaseWorkspaceResourcesHandlerType = @import("../../application/workspaces/ReleaseWorkspaceResourcesHandler.zig");
const WorkspaceActivationType = @import("../../model/WorkspaceActivation.zig");
const ActivateWorkspaceHandlerType = @import("../../application/workspaces/ActivateWorkspaceHandler.zig");
const ReleaseEffectsType = @import("../../application/workspaces/ReleaseEffects.zig");
const ActivationEffectsType = @import("../../application/workspaces/ActivationEffects.zig");
const WorkspaceBookmarkType = @import("../../model/WorkspaceBookmark.zig");
const PaneIdType = @import("telar-core").PaneId;
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const TabLocationType = @import("telar-core").TabLocation;

/// Builds a workspace arrival from the runtime-selected root and an exact
/// remembered layout when that bookmark still names the same tab.
///
/// ```zig
/// const command = arrival(client, opened, requested_size);
/// ```
pub fn arrival(client: *Client, opened: OpenedPaneType, size: TerminalSizeType) WorkspaceArrivalType {
    const planner = arrivalPlanner(client);

    return planner.execute(opened, size);
}

fn arrivalPlanner(client: *Client) PlanWorkspaceArrivalHandlerType {
    return .{ .bookmarks = .{
        .context = client,
        .find = findBookmark,
    } };
}

fn findBookmark(context: *anyopaque, workspace: WorkspaceLocationType) ?BookmarkType {
    const client: *Client = @ptrCast(@alignCast(context));
    const bookmark = client.navigation_history.find(workspace) orelse return null;

    return .{
        .location = bookmark.location,
        .tab_layout = bookmark.tab_layout,
    };
}

/// Retains the navigation bookmark and releases resources captured by a
/// committed departure. No protocol detach or focus-out is emitted.
///
/// ```zig
/// release(client, &departure);
/// ```
pub fn release(client: *Client, departure: *const WorkspaceDepartureType) void {
    var use_case: ReleaseWorkspaceResourcesHandlerType = .{
        .model = &client.model,
        .effects = releaseEffects(client),
    };

    use_case.execute(departure);
}

/// Activates the root selected by the runtime, then requests both canonical
/// snapshots needed to complete the new projection.
///
/// ```zig
/// try activate(client, activation);
/// ```
pub fn activate(client: *Client, activation: WorkspaceActivationType) !void {
    var use_case: ActivateWorkspaceHandlerType = .{
        .model = &client.model,
        .effects = activationEffects(client),
    };

    try use_case.execute(activation);
}

/// Returns release ports reused by compound workspace transitions.
///
/// ```zig
/// const effects = releaseEffects(client);
/// ```
pub fn releaseEffects(client: *Client) ReleaseEffectsType {
    return .{
        .context = client,
        .remember_bookmark = rememberBookmark,
        .clear_pane_graphics = clearPaneGraphics,
    };
}

/// Returns activation ports reused by compound workspace transitions.
///
/// ```zig
/// const effects = activationEffects(client);
/// ```
pub fn activationEffects(client: *Client) ActivationEffectsType {
    return .{
        .context = client,
        .synchronize_active_resources = synchronizeActiveResources,
        .schedule_host_input = scheduleHostInput,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn rememberBookmark(raw_context: *anyopaque, bookmark: WorkspaceBookmarkType) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.navigation_history.remember(.{
        .location = bookmark.location,
        .pane_id = bookmark.pane_id,
        .tab_layout = bookmark.tab_layout,
    });
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.graphics.clearPane(pane_id);
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try active_pane_resources.synchronize(client);
}

fn scheduleHostInput(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try client.host_input_source.resumeRead();
}

fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}

fn requestTabSnapshot(raw_context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
