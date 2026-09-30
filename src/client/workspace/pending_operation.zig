//! Tab and workspace operations wait for the runtime's answer one at a
//! time, so the replica never guesses the order. One asked for meanwhile,
//! such as a second new-tab key press before the first tab arrived, is
//! dropped and its limit named.
const data = @import("model");
const limit_reached = @import("../notifications/limit_reached.zig");
const Client = @import("../execution/Client.zig");

/// Whether an operation of `group` still waits; when one does, the new
/// one is dropped and the limit reported.
///
/// ```zig
/// if (pending_operation.waits(client, .tab_operation)) return false;
/// ```
pub fn waits(client: *Client, group: data.RequestsGroup) bool {
    if (!client.model.request_lifecycle.tracker.has(group)) {
        return false;
    }

    limit_reached.report(client, .{
        .limit = if (group == .workspace_operation) data.Tracker.workspace_operation_limit else data.Tracker.tab_operation_limit,
        .requested = 2,
    });
    return true;
}
