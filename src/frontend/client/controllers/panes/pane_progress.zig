//! Adapts runtime progress reports to pane state and the shared animation clock.

const core = @import("telar-core");
const client_model = @import("../../model/root.zig");
const sidebar_animations = @import("../notifications/sidebar_animations.zig");

const Client = @import("../../client.zig");
const schema = core.schema;

/// Stores one decoded terminal progress report and maintains animation liveness.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: schema.PaneProgress) !?client_model.PaneProgressCommit {
    const commit = client.model.updatePaneProgress(message) orelse return null;
    _ = try sidebar_animations.synchronize(client);
    return commit;
}
