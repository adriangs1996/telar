//! Adapts runtime resynchronization requirements to client application policy.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const ResyncRequiredType = @import("telar-core").ResyncRequired;
pub const Outcome = enum { coalesced, snapshot_requested, handoff_requested, exit };

/// Resolves disposable client state and applies one validated runtime resync.
/// The client loop maps only the returned `exit` outcome to process status.
///
/// ```zig
/// const outcome = try apply(client, required);
/// ```
pub fn apply(client: *Client, required: ResyncRequiredType) !Outcome {
    if (required.workspace_closed) {
        client.navigation_history.forget(required.workspace);
        const previous = required.previous_workspace orelse return .exit;
        _ = try client.requestWorkspace(previous);
        return .handoff_requested;
    }

    const projected = client.model.workspaceLocation() orelse return error.UnexpectedResync;
    if (!std.meta.eql(projected, required.workspace)) {
        return error.UnexpectedResync;
    }
    if (client.request_lifecycle.tracker.has(.workspace_snapshot)) {
        return .coalesced;
    }

    try client.requestWorkspaceSnapshot(required.workspace);
    return .snapshot_requested;
}
