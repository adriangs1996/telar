const Client = @import("../../AttachedClient.zig");
const PaneClipboard = @import("telar-core").PaneClipboard;

/// Delivers borrowed clipboard bytes synchronously to the host. Example: `try apply(client, clipboard);`
pub fn apply(client: *Client, clipboard: PaneClipboard) !void {
    if (clipboard.pane_id == .invalid) {
        return error.UnexpectedPane;
    }

    try client.host_clipboard.set(client.host_clipboard.context, clipboard.bytes);
}
