//! Wires per-pane attachment confirmation and canonical recovery to a client.

const Client = @import("../../Client.zig");
const ConfirmPaneAttachmentHandlerType = @import("telar-client").ConfirmPaneAttachmentHandler;
const RecoverPaneAttachmentHandlerType = @import("telar-client").RecoverPaneAttachmentHandler;
const RequestTabSnapshotRecoveryHandlerType = @import("telar-client").RequestTabSnapshotRecoveryHandler;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const TabLocationType = @import("telar-core").TabLocation;

/// Wires a runtime attachment confirmation to the passive client model.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) ConfirmPaneAttachmentHandlerType {
    return .{ .model = &client.model };
}

/// Wires a stale membership failure to one coalesced canonical tab snapshot.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(attachment);
/// ```
pub fn recoveryHandler(client: *Client) RecoverPaneAttachmentHandlerType {
    return .{
        .model = &client.model,
        .snapshots = snapshotRecovery(client),
    };
}

fn snapshotRecovery(client: *Client) RequestTabSnapshotRecoveryHandlerType {
    return .{ .effects = .{
        .context = client,
        .pending = tabSnapshotPending,
        .request = requestTabSnapshot,
    } };
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
