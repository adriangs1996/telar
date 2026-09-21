const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const ResizePaneRequest = @import("../../model/ResizePaneRequest.zig");
const TogglePaneFullscreenRequest = @import("../../model/TogglePaneFullscreenRequest.zig");
const PaneGeometryChange = @import("../../model/PaneGeometryChange.zig");

/// Commits one split-edge move before delivering geometry. Example: `_ = try resize(client, command);`
pub fn resize(client: *Client, command: ResizePaneRequest) !?PaneGeometryChange {
    const change = client.model.resizePane(command) orelse return null;
    try deliver(client, change);

    return change;
}

/// Commits fullscreen state before delivering geometry. Example: `_ = try toggleFullscreen(client, command);`
pub fn toggleFullscreen(client: *Client, command: TogglePaneFullscreenRequest) !?PaneGeometryChange {
    const change = client.model.togglePaneFullscreen(command) orelse return null;
    try deliver(client, change);

    return change;
}

fn deliver(client: *Client, change: PaneGeometryChange) !void {
    const active = client.model.workspace.active() orelse return error.StalePaneGeometry;
    if (!std.meta.eql(active.location, change.location) or
        active.model.layout.focused() != change.focused or
        active.model.layout.isFullscreen() != change.fullscreen or
        client.model.version().panes != change.panes_revision)
    {
        return error.StalePaneGeometry;
    }

    client.host_graphics.invalidatePlacements();
    try client.resizeAttachedPanes(&active.model, change.area);

    if (active.snapshot_loaded) {
        try client.attachVisiblePanes(active, change.area);
    }
}
