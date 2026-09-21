const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const multiplexer = @import("../../workspace/multiplexer.zig");
const ResizePaneRequest = @import("../../model/ResizePaneRequest.zig");
const TogglePaneFullscreenRequest = @import("../../model/TogglePaneFullscreenRequest.zig");
const PaneGeometryChange = @import("../../model/PaneGeometryChange.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const tab_snapshots = @import("../tabs/tab_snapshots.zig");

const Rect = @import("telar-core").Rect;

/// Offers attached visible pane sizes, including the attachment shelf reservation. Example: `try offerAttached(client, model, area);`
pub fn offerAttached(client: *Client, model: *MultiplexerModel, area: Rect) !void {
    var layout = model.layoutSnapshot(area).*;
    _ = layout.reserveBelowPane(client.attachment_shelf.reservation());
    var panes = model.paneIterator();
    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
        try runtime_transport.enqueue(client, .{ .pane_resize = .{ .pane_id = pane.id, .size = size } });
    }
}

/// Offers geometry for the active tab when one exists. Example: `try offerActive(client, area);`
pub fn offerActive(client: *Client, area: Rect) !void {
    const active = client.model.workspace.active() orelse return;
    try offerAttached(client, &active.model, area);
}

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
    try offerAttached(client, &active.model, change.area);
    try tab_snapshots.attachActive(client, change.area);
}
