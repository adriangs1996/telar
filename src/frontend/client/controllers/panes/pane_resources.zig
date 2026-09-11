//! Disposable client resources keyed by pane identity.

const Client = @import("../../Client.zig");
const PaneIdType = @import("telar-core").PaneId;
const ReleasePaneResourcesHandlerType = @import("telar-client").ReleasePaneResourcesHandler;

/// Releases copy, paste, focus and graphics state retained for one pane.
/// Repeated release is harmless.
///
/// ```zig
/// release(client, pane_id);
/// ```
pub fn release(client: *Client, pane_id: PaneIdType) void {
    var use_case: ReleasePaneResourcesHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .clear_graphics = clearGraphics,
        },
    };

    _ = use_case.execute(pane_id);
}

fn clearGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}
