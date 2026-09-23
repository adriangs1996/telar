//! Pane resize: commits split and fullscreen changes and delivers the new
//! geometry to the runtime.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_attachment = @import("pane_attachment.zig");
const pane_focus = @import("pane_focus.zig");
const Client = @import("../AttachedClient.zig");

/// Commits one split-edge move before delivering geometry. Example: `_ = try pane_resize.resizePane(client, command);`
pub fn resizePane(client: *Client, command: data.ResizePaneRequest) !?data.PaneGeometryChange {
    const change = client.model.resizePane(command) orelse return null;
    try deliverPaneGeometry(client, change);

    return change;
}

/// Commits fullscreen state before delivering geometry. Example: `_ = try pane_resize.togglePaneFullscreen(client, command);`
pub fn togglePaneFullscreen(client: *Client, command: data.TogglePaneFullscreenRequest) !?data.PaneGeometryChange {
    const change = client.model.togglePaneFullscreen(command) orelse return null;
    try deliverPaneGeometry(client, change);

    return change;
}

/// Offers sizes for attached visible panes, reserving space for the attachment shelf.
/// Example: `try pane_resize.resizeAttachedPanes(client, tab, area);`
pub fn resizeAttachedPanes(client: *Client, tab: usize, area: core.Rect) !void {
    var layout = data.tab_layout.snapshot(&client.model, tab, area).*;
    _ = layout.reserveBelowPane(if (client.attachments) |shelf| shelf.reservation() else null);
    var panes = client.model.panes.iterate(client.model.tabs.location[tab].tab_id);

    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = data.multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = client.model.host.host_size.cell_width_px;
        size.cell_height_px = client.model.host.host_size.cell_height_px;
        try client.model.to_runtime.push(
            .{
                .pane_resize = .{
                    .pane_id = pane.id,
                    .size = size,
                },
            },
        );
    }
}

/// Rejects obsolete geometry before invalidating placements and resizing attachments.
fn deliverPaneGeometry(client: *Client, change: data.PaneGeometryChange) !void {
    const active = client.model.tabs.activeSlot() orelse return error.StalePaneGeometry;
    if (!std.meta.eql(client.model.tabs.location[active], change.location) or
        client.model.tabs.layout[active].focused() != change.focused or
        client.model.tabs.layout[active].isFullscreen() != change.fullscreen or
        client.model.version().panes != change.panes_revision)
    {
        return error.StalePaneGeometry;
    }

    client.model.to_host.invalidate_placements = true;
    try resizeAttachedPanes(client, active, change.area);

    if (client.model.tabs.snapshot_loaded[active]) {
        try pane_attachment.attachVisiblePanes(&client.model, active, change.area);
    }
}

/// Commits a membership-checked layout before delivering its geometry.
pub fn applyPaneLayout(client: *Client, request: data.PaneLayoutRequest) !void {
    const focus = try client.model.applyPaneLayout(request);
    try pane_focus.deliverPaneFocus(client, focus, request.area);
}
