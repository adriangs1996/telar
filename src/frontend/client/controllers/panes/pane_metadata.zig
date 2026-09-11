//! Adapts runtime pane metadata messages to the client application boundary.

const Client = @import("../../Client.zig");
const PaneCwdType = @import("telar-core").PaneCwd;
const PaneMetadataCommitType = @import("telar-client").PaneMetadataCommit;
const PaneForegroundType = @import("telar-core").PaneForeground;
const PaneTitleType = @import("telar-core").PaneTitle;

/// Stores one decoded pane working-directory fact.
///
/// ```zig
/// _ = try applyCwd(client, message);
/// ```
pub fn applyCwd(client: *Client, message: PaneCwdType) !?PaneMetadataCommitType {
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
pub fn applyForeground(client: *Client, message: PaneForegroundType) !?PaneMetadataCommitType {
    return client.model.updatePaneMetadata(.{ .foreground = .{
        .pane_id = message.pane_id,
        .name = message.name,
    } });
}

/// Stores one decoded pane window-title fact.
///
/// ```zig
/// _ = try applyTitle(client, message);
/// ```
pub fn applyTitle(client: *Client, message: PaneTitleType) !?PaneMetadataCommitType {
    return client.model.updatePaneMetadata(.{ .title = .{
        .pane_id = message.pane_id,
        .title = message.title,
    } });
}
