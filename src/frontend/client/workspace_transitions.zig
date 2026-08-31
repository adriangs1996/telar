//! Adapts committed workspace transitions to navigation and client ports.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const host_inputs = @import("host_inputs.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const request_lifecycle = @import("request_lifecycle.zig");

const Client = @import("client.zig");
const workspace_transition_delivery = client_application.workspace_transition_delivery;
const schema = core.schema;

/// Builds a workspace arrival from the runtime-selected root and an exact
/// remembered layout when that bookmark still names the same tab.
///
/// ```zig
/// const command = arrival(client, opened, requested_size);
/// ```
pub fn arrival(client: *Client, opened: schema.PaneOpened, size: schema.TerminalSize) client_model.WorkspaceArrival {
    const saved_layout = if (client.navigation_history.find(opened.location.workspace)) |bookmark|
        if (std.meta.eql(bookmark.location, opened.location)) bookmark.tab_layout else null
    else
        null;

    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .size = size,
        .saved_layout = saved_layout,
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
        .effects = .{
            .context = client,
            .remember_bookmark = rememberBookmark,
            .clear_pane_graphics = clearPaneGraphics,
        },
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
        .effects = .{
            .context = client,
            .synchronize_active_resources = synchronizeActiveResources,
            .schedule_host_input = scheduleHostInput,
            .request_workspace_snapshot = requestWorkspaceSnapshot,
            .request_tab_snapshot = requestTabSnapshot,
        },
    };

    try use_case.execute(activation);
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
