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
    if (clipboard.pane_id == .invalid) {
        return error.UnexpectedPane;
    }

    try term.writeClipboard(client.writer, clipboard.bytes);
    try client.writer.flush();
}
