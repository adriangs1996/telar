//! Writes runtime-approved pane clipboard payloads to the host terminal.

const Client = @import("../../Client.zig");
const PaneClipboardType = @import("telar-core").PaneClipboard;
const HandlerType = @import("telar-client").PaneClipboardHandler;
const term = @import("../../../presentation/screen_support.zig");

/// Writes one borrowed pane clipboard payload as OSC 52 and flushes it.
///
/// ```zig
/// try apply(client, clipboard);
/// ```
pub fn apply(client: *Client, clipboard: PaneClipboardType) !void {
    const handler: HandlerType = .{
        .clipboard = .{ .context = client, .set = setClipboard },
    };
    try handler.execute(clipboard);
}

fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try term.writeClipboard(client.writer, bytes);
    try client.writer.flush();
}
