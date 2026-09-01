//! Wires per-pane attachment confirmation and canonical recovery to a client.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const attach_pane = client_application.attach_pane;
const request_lifecycle = @import("request_lifecycle.zig");
const schema = core.schema;
const tab_snapshot_recovery = client_application.tab_snapshot_recovery;

/// Wires a runtime attachment confirmation to the passive client model.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) attach_pane.ConfirmPaneAttachmentHandler {
    return .{ .model = &client.model };
}

/// Wires a stale membership failure to one coalesced canonical tab snapshot.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(attachment);
/// ```
pub fn recoveryHandler(client: *Client) attach_pane.RecoverPaneAttachmentHandler {
    return .{
        .model = &client.model,
        .snapshots = snapshotRecovery(client),
    };
}

fn snapshotRecovery(client: *Client) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
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

fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
