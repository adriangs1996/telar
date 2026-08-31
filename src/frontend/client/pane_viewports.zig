//! Wires committed pane viewports to graphics and the runtime attachment.

const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const runtime_transport = @import("runtime_transport.zig");
const set_pane_viewport = client_application.set_pane_viewport;

pub const Target = client_model.PaneViewportTarget;

/// Wires viewport intent to the shared graphics and runtime effect.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .pane_id = pane_id, .target = .bottom });
/// ```
pub fn handler(client: *Client) set_pane_viewport.SetPaneViewportHandler {
    return .{
        .model = &client.model,
        .effects = effects(client),
    };
}

/// Returns the viewport effect port reused by compound client transactions.
///
/// ```zig
/// const viewport_effects = effects(client);
/// ```
pub fn effects(client: *Client) set_pane_viewport.PaneViewportEffects {
    return .{
        .context = client,
        .sync = sync,
    };
}

fn sync(context: *anyopaque, change: client_model.PaneViewportChange) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const active = client.model.workspace.active() orelse return error.UnexpectedPaneViewport;
    const pane = active.model.find(change.pane_id) orelse return error.UnexpectedPaneViewport;
    if (!pane.attached or pane.scroll.offset != change.offset or
        pane.scroll.atBottom(pane.buffer.h) != change.at_bottom or
        client.model.version().viewport != change.viewport_revision)
    {
        return error.UnexpectedPaneViewport;
    }

    try client.graphics_store.setPaneVisible(change.pane_id, change.at_bottom);
    try runtime_transport.enqueue(client, .{ .set_pane_viewport = .{
        .pane_id = change.pane_id,
        .offset = change.offset,
    } });
}
