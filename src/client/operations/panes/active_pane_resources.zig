const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const pane_focus_reports = @import("pane_focus_reports.zig");
const PaneFocus = @import("../../model/PaneFocus.zig");

const Rect = @import("telar-core").Rect;

/// Synchronizes the focused attachment before reporting child focus. Example: `try synchronize(client);`
pub fn synchronize(client: *Client) !void {
    _ = try synchronizeAttachments(client);
    _ = try pane_focus_reports.sync(client);
}

/// Acknowledges a completed agent and reconciles its focused attachment shelf. Example: `_ = try synchronizeAttachments(client);`
pub fn synchronizeAttachments(client: *Client) !bool {
    if (client.model.takeAgentAcknowledgement()) |key| {
        try client.sendRuntime(
            .{
                .acknowledge_agent = .{
                    .pane_id = key.pane_id,
                    .pane_generation = key.pane_generation,
                },
            },
        );
    }

    if (!client.attachment_shelf.syncTarget(client.model.focusedAttachmentTarget())) {
        return false;
    }

    if (client.model.workspace.active()) |tab| {
        try client.resizeAttachedPanes(&tab.model, client.geometry().area);
    }

    return true;
}

/// Delivers resources for a committed focus, including newly revealed panes. Example: `try deliverFocus(client, focus, area);`
pub fn deliverFocus(client: *Client, focus: PaneFocus, area: Rect) !void {
    const active = client.model.workspace.active() orelse return error.StalePaneFocus;
    if (!std.meta.eql(active.location, focus.location) or
        active.model.layout.focused() != focus.focused or
        client.model.version().panes != focus.panes_revision)
    {
        return error.StalePaneFocus;
    }

    try synchronize(client);
    if (!focus.geometry_changed) {
        return;
    }

    client.host_graphics.invalidatePlacements();
    try client.resizeAttachedPanes(&active.model, area);

    if (active.snapshot_loaded) {
        try client.attachVisiblePanes(active, area);
    }
}
