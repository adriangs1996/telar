//! Resync required: the runtime lost track of this client, so the client asks
//! for fresh snapshots or hands the session off.
const core = @import("telar-core");
const std = @import("std");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const workspace_list_snapshot = @import("../workspace/workspace_list_snapshot.zig");
const Client = @import("../AttachedClient.zig");

const ResyncOutcome = enum { coalesced, snapshot_requested, handoff_requested, exit };

/// Resolves disposable client state and applies one validated runtime resync.
/// The client loop maps only the returned `exit` outcome to process status.
pub fn applyResyncRequirement(client: *Client, required: core.ResyncRequired) !ResyncOutcome {
    if (required.workspace_closed) {
        client.model.navigation_history.forget(required.workspace);
        const previous = required.previous_workspace orelse return .exit;
        _ = try workspace_handoff.requestWorkspace(client, previous);
        return .handoff_requested;
    }

    const projected = client.model.workspace orelse return error.UnexpectedResync;
    if (!std.meta.eql(projected, required.workspace)) {
        return error.UnexpectedResync;
    }

    if (client.model.request_lifecycle.tracker.has(.workspace_snapshot)) {
        return .coalesced;
    }

    try workspace_list_snapshot.requestWorkspaceSnapshot(&client.model, required.workspace);
    return .snapshot_requested;
}
