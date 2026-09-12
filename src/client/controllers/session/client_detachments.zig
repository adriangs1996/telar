//! Detaches every runtime pane attachment owned by one client.

const Client = @import("../../AttachedClient.zig");
const DetachClientHandlerType = @import("../../application/session/DetachClientHandler.zig");
const TabLocationType = @import("telar-core").TabLocation;
const tab_attachments = @import("../tabs/tab_attachments.zig");

/// Detaches every tab in stable client order before the event loop exits.
///
/// ```zig
/// try apply(client);
/// ```
pub fn apply(client: *Client) !void {
    var use_case: DetachClientHandlerType = .{
        .model = &client.model,
        .effects = .{ .context = client, .detach_tab = detachTab },
    };

    try use_case.execute();
}

fn detachTab(raw_context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try tab_attachments.detach(client, location);
}
