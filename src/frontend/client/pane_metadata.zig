//! Adapts runtime pane metadata messages to the client application boundary.

const core = @import("telar-core");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const schema = core.schema;

/// Stores one decoded pane working-directory fact.
///
/// ```zig
/// _ = try applyCwd(client, message);
/// ```
pub fn applyCwd(client: *Client, message: schema.PaneCwd) !?client_model.PaneMetadataCommit {
    return client.model.updatePaneMetadata(.{ .cwd = .{
        .pane_id = message.pane_id,
        .path = message.cwd,
    } });
}

/// Stores one decoded pane foreground-process fact.
///
/// ```zig
/// _ = try applyForeground(client, message);
/// ```
pub fn applyForeground(client: *Client, message: schema.PaneForeground) !?client_model.PaneMetadataCommit {
    return client.model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = message.pane_id,
        .name = message.name,
    } });
}
