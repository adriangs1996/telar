//! Detaches every runtime pane attachment owned by one client.

const core = @import("telar-core");
const session_application = @import("../../application/session/root.zig");

const Client = @import("../../client.zig");
const tab_attachments = @import("../tabs/tab_attachments.zig");

const client_detachment = session_application.client_detachment;
const schema = core.schema;

/// Detaches every tab in stable client order before the event loop exits.
///
/// ```zig
/// try apply(client);
/// ```
pub fn apply(client: *Client) !void {
    var use_case: client_detachment.DetachClientHandler = .{
        .model = &client.model,
        .effects = .{ .context = client, .detach_tab = detachTab },
    };

    try use_case.execute();
}

fn detachTab(raw_context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try tab_attachments.detach(client, location);
}
