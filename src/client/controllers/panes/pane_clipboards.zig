//! Delivers runtime-approved pane clipboard payloads to the host clipboard port.

const Client = @import("../../AttachedClient.zig");
const PaneClipboardType = @import("telar-core").PaneClipboard;
const HandlerType = @import("../../application/panes/PaneClipboardHandler.zig");

/// Hands one borrowed pane clipboard payload to the host clipboard port.
///
/// ```zig
/// try apply(client, clipboard);
/// ```
pub fn apply(client: *Client, clipboard: PaneClipboardType) !void {
    const handler: HandlerType = .{ .clipboard = client.host_clipboard };

    try handler.execute(clipboard);
}
