//! Adapts committed workspace transitions to navigation and client ports.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");
const workspaces_application = @import("../../application/workspaces/root.zig");
const client_model = @import("../../model/root.zig");
const host_inputs = @import("../input/host_inputs.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const Client = @import("../../client.zig");
const pane_open_delivery = panes_application.pane_open_delivery;
const workspace_arrival_planning = workspaces_application.workspace_arrival_planning;
const workspace_transition_delivery = workspaces_application.workspace_transition_delivery;
const schema = core.schema;

/// Builds a workspace arrival from the runtime-selected root and an exact
/// remembered layout when that bookmark still names the same tab.
///
/// ```zig
/// const command = arrival(client, opened, requested_size);
/// ```
pub fn arrival(client: *Client, opened: pane_open_delivery.OpenedPane, size: schema.TerminalSize) client_model.WorkspaceArrival {
    const planner = arrivalPlanner(client);

    return planner.execute(opened, size);
}

fn arrivalPlanner(client: *Client) workspace_arrival_planning.PlanWorkspaceArrivalHandler {
    return .{ .bookmarks = .{
        .context = client,
        .find = findBookmark,
    } };
}

fn findBookmark(context: *anyopaque, workspace: schema.WorkspaceLocation) ?workspace_arrival_planning.Bookmark {
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
pub fn release(client: *Client, departure: *const client_model.WorkspaceDeparture) void {
    var use_case: workspace_transition_delivery.ReleaseWorkspaceResourcesHandler = .{
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
pub fn activate(client: *Client, activation: client_model.WorkspaceActivation) !void {
    var use_case: workspace_transition_delivery.ActivateWorkspaceHandler = .{
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
pub fn releaseEffects(client: *Client) workspace_transition_delivery.ReleaseEffects {
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
pub fn activationEffects(client: *Client) workspace_transition_delivery.ActivationEffects {
    return .{
        .context = client,
        .synchronize_active_resources = synchronizeActiveResources,
        .schedule_host_input = scheduleHostInput,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

fn rememberBookmark(raw_context: *anyopaque, bookmark: client_model.WorkspaceBookmark) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.navigation_history.remember(.{
        .location = bookmark.location,
        .pane_id = bookmark.pane_id,
        .tab_layout = bookmark.tab_layout,
    });
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.graphics_store.clearPane(pane_id);
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try active_pane_resources.synchronize(client);
}

fn scheduleHostInput(raw_context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try host_inputs.scheduleRead(client);
}

fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}

fn requestTabSnapshot(raw_context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
