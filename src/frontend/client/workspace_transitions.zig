//! Shared post-commit resource effects for workspace projection changes.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const pane_resources = @import("pane_resources.zig");

const Client = @import("client.zig");
const schema = core.schema;

pub const Activation = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
};

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
    if (departure.bookmark) |bookmark| {
        client.navigation_history.remember(.{
            .location = bookmark.location,
            .pane_id = bookmark.pane_id,
            .tab_layout = bookmark.tab_layout,
        });
    }

    for (departure.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    _ = client.model.forgetReportedPaneFocus();
}

/// Activates the root selected by the runtime, then requests both canonical
/// snapshots needed to complete the new projection.
///
/// ```zig
/// try activate(client, .{ .pane_id = pane_id, .location = location });
/// ```
pub fn activate(client: *Client, activation: Activation) !void {
    const active = client.model.workspace.active() orelse return error.UnexpectedRequest;
    if (!std.meta.eql(active.location, activation.location) or
        active.model.find(activation.pane_id) == null)
    {
        return error.UnexpectedRequest;
    }

    try pane_focus.syncResources(client);
    try client.scheduleInputRead();
    try client.requestWorkspaceSnapshot(activation.location.workspace);
    try client.requestTabSnapshot(activation.location);
}
