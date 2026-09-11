const Handler = @This();
const Clipboard = @import("Clipboard.zig");
const schema = @import("telar-core").schema;
clipboard: Clipboard,

/// Delivers borrowed bytes synchronously; an asynchronous host must copy them.
/// Example: `try handler.execute(message);`.
pub fn execute(handler: Handler, message: schema.PaneClipboard) !void {
    if (message.pane_id == .invalid) {
        return error.UnexpectedPane;
    }

    try handler.clipboard.set(handler.clipboard.context, message.bytes);
}
