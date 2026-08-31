//! Detaches every runtime pane attachment owned by one client.

const Client = @import("client.zig");
const tab_attachments = @import("tab_attachments.zig");

/// Detaches every tab in stable client order before the event loop exits.
///
/// ```zig
/// try apply(client);
/// ```
pub fn apply(client: *Client) !void {
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        try tab_attachments.detach(client, tab.location);
    }
}
