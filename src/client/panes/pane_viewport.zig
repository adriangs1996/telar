//! Pane viewport: scrolls a pane and delivers its viewport to the runtime.
const data = @import("model");
const pane_mouse_input = @import("../input/pane_mouse_inputs.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const Client = @import("../execution/Client.zig");

pub fn scrollPane(client: *Client, direction: data.ScrollDirection) !void {
    const model = client.model.tabs.activeSlot() orelse return;

    _ = try pane_mouse_input.inputPaneMouse(
        client,
        model,
        .{
            .focused_scroll = direction,
        },
    );
}

/// Commits a bounded viewport, then updates graphics and the runtime. Example: `_ = try apply(client, command);`
pub fn applyPaneViewport(client: *Client, command: data.PaneViewportCommand) !?data.PaneViewportChange {
    const change = client.model.setPaneViewport(command) orelse return null;
    try deliverPaneViewport(client, change);

    return change;
}

/// Delivers a viewport committed by this or a compound input operation. Example: `try deliver(client, change);`
pub fn deliverPaneViewport(client: *Client, change: data.PaneViewportChange) !void {
    const active = client.model.tabs.activeSlot() orelse return error.StalePaneViewport;
    const pane = client.model.panes.findInConst(client.model.tabs.location[active].tab_id, change.pane_id) orelse return error.StalePaneViewport;
    if (!pane.attached or
        pane.scroll.offset != change.offset or
        pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
        client.model.version().viewport != change.viewport_revision)
    {
        return error.StalePaneViewport;
    }

    try client.graphics.setPaneVisible(change.pane_id, change.at_bottom);
    try client.model.to_runtime.push(
        .{
            .set_pane_viewport = .{
                .pane_id = change.pane_id,
                .offset = change.offset,
            },
        },
    );
}
