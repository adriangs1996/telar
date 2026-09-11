const Clipboard = @import("Clipboard.zig");
const PaneClipboardType = @import("telar-core").PaneClipboard;
const Handler = @This();

clipboard: Clipboard,

/// Delivers borrowed bytes synchronously; an asynchronous host must copy them.
/// Example: `try handler.execute(message);`.
pub fn execute(handler: Handler, message: PaneClipboardType) !void {
    if (message.pane_id == .invalid) {
        return error.UnexpectedPane;
    }

    try handler.clipboard.set(handler.clipboard.context, message.bytes);
}
