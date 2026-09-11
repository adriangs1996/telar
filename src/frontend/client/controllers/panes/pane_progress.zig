//! Adapts runtime progress reports to pane state and the shared animation clock.

const Client = @import("../../Client.zig");
const PaneProgressType = @import("telar-core").PaneProgress;
const PaneProgressCommitType = @import("telar-client").PaneProgressCommit;
const sidebar_animations = @import("../notifications/sidebar_animations.zig");

/// Stores one decoded terminal progress report and maintains animation liveness.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: PaneProgressType) !?PaneProgressCommitType {
    const commit = client.model.updatePaneProgress(message) orelse return null;
    _ = try sidebar_animations.synchronize(client);
    return commit;
}
