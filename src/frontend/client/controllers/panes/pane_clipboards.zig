//! Writes runtime-approved pane clipboard payloads to the host terminal.

const core = @import("telar-core");
const presentation = @import("../../../presentation/root.zig");

const Client = @import("../../client.zig");
const schema = core.schema;
const term = presentation.screen;

/// Writes one borrowed pane clipboard payload as OSC 52 and flushes it.
///
/// ```zig
/// try apply(client, clipboard);
/// ```
pub fn apply(client: *Client, clipboard: schema.PaneClipboard) !void {
    const handler: @import("telar-client").application.panes.pane_clipboard.Handler = .{
        .clipboard = .{ .context = client, .set = setClipboard },
    };
    try handler.execute(clipboard);
}

fn setClipboard(context: *anyopaque, bytes: []const u8) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try term.writeClipboard(client.writer, bytes);
    try client.writer.flush();
}
