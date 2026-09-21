const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const OpenedPane = @import("../../application/panes/OpenedPane.zig");
const WorkspaceArrival = @import("../../model/WorkspaceArrival.zig");
const WorkspaceDeparture = @import("../../model/WorkspaceDeparture.zig");
const WorkspaceActivation = @import("../../model/WorkspaceActivation.zig");
const pane_resources = @import("../panes/pane_resources.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const TerminalSize = @import("telar-core").TerminalSize;

/// Uses a saved layout only when it belongs to the exact runtime-selected tab. Example: `const command = arrival(client, opened, size);`
pub fn arrival(client: *Client, opened: OpenedPane, size: TerminalSize) WorkspaceArrival {
    const bookmark = client.navigation_history.find(opened.location.workspace);
    const saved_layout = if (bookmark) |remembered|
        if (std.meta.eql(remembered.location, opened.location)) remembered.tab_layout else null
    else
        null;

    return .{ .pane_id = opened.pane_id, .location = opened.location, .size = size, .saved_layout = saved_layout };
}

/// Retains the bookmark before releasing departed resources without child input. Example: `release(client, &departure);`
pub fn release(client: *Client, departure: *const WorkspaceDeparture) void {
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

/// Activates the committed root before resuming input and requesting canonical snapshots. Example: `try activate(client, activation);`
pub fn activate(client: *Client, activation: WorkspaceActivation) !void {
    const active = client.model.workspace.activeConst() orelse return error.StaleWorkspaceActivation;
    const root = active.model.findConst(activation.pane_id) orelse return error.StaleWorkspaceActivation;
    const version = client.model.version();
    if (!std.meta.eql(active.location, activation.location) or
        active.model.pane_count != 1 or
        active.model.layout.focused() != activation.pane_id or
        !std.meta.eql(root.location, activation.location) or
        !root.attached or
        version.workspace != activation.workspace_revision or
        version.tabs != activation.tabs_revision or
        version.active_tab != activation.active_tab_revision or
        version.panes != activation.panes_revision or
        version.copy != activation.copy_revision or
        activation.workspace_revision_before +% 1 != activation.workspace_revision or
        activation.tabs_revision_before +% 1 != activation.tabs_revision or
        activation.active_tab_revision_before +% 1 != activation.active_tab_revision or
        activation.panes_revision_before +% 1 != activation.panes_revision or
        activation.copy_revision_before +% @intFromBool(activation.copy_released) != activation.copy_revision)
    {
        return error.StaleWorkspaceActivation;
    }
    try active_pane_resources.synchronize(client);
    try client.host_input_source.resumeRead();
    try request_lifecycle.requestWorkspaceSnapshot(client, activation.location.workspace);
    try request_lifecycle.requestTabSnapshot(client, activation.location);
}
