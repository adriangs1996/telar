const Client = @import("../../AttachedClient.zig");
const PaneViewportCommand = @import("../../model/PaneViewportCommand.zig");
const PaneViewportChange = @import("../../model/PaneViewportChange.zig");

/// Commits a bounded viewport, then updates graphics and the runtime. Example: `_ = try apply(client, command);`
pub fn apply(client: *Client, command: PaneViewportCommand) !?PaneViewportChange {
    const change = client.model.setPaneViewport(command) orelse return null;
    try deliver(client, change);

    return change;
}

/// Delivers a viewport committed by this or a compound input operation. Example: `try deliver(client, change);`
pub fn deliver(client: *Client, change: PaneViewportChange) !void {
    const active = client.model.workspace.activeConst() orelse return error.StalePaneViewport;
    const pane = active.model.findConst(change.pane_id) orelse return error.StalePaneViewport;
    if (!pane.attached or
        pane.scroll.offset != change.offset or
        pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
        client.model.version().viewport != change.viewport_revision)
    {
        return error.StalePaneViewport;
    }

    try client.graphics.setPaneVisible(change.pane_id, change.at_bottom);
    try client.sendRuntime(
        .{
            .set_pane_viewport = .{
                .pane_id = change.pane_id,
                .offset = change.offset,
            },
        },
    );
}
