//! Disposable client resources keyed by pane identity.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");

const Client = @import("../../client.zig");
const pane_resource_release = panes_application.pane_resource_release;
const schema = core.schema;

/// Releases copy, paste, focus and graphics state retained for one pane.
/// Repeated release is harmless.
///
/// ```zig
/// release(client, pane_id);
/// ```
pub fn release(client: *Client, pane_id: schema.PaneId) void {
    var use_case: pane_resource_release.ReleasePaneResourcesHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .clear_graphics = clearGraphics,
        },
    };

    _ = use_case.execute(pane_id);
}

fn clearGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}
