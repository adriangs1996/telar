//! Delivery of runtime-approved clipboard bytes through the host clipboard port.
const std = @import("std");
const schema = @import("telar-core").schema;

pub const Clipboard = struct {
    context: *anyopaque,
    set: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const Handler = struct {
    clipboard: Clipboard,

    /// Delivers borrowed bytes synchronously; an asynchronous host must copy them.
    /// Example: `try handler.execute(message);`.
    pub fn execute(handler: Handler, message: schema.PaneClipboard) !void {
        if (message.pane_id == .invalid) {
            return error.UnexpectedPane;
        }

        try handler.clipboard.set(handler.clipboard.context, message.bytes);
    }
};

const Capture = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,
    fail: bool = false,

    fn set(context: *anyopaque, bytes: []const u8) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        if (capture.fail) {
            return error.ClipboardUnavailable;
        }

        @memcpy(capture.bytes[0..bytes.len], bytes);
        capture.len = bytes.len;
    }
};

test "clipboard delivery preserves validation and host failure without a terminal writer" {
    var capture: Capture = .{};
    const handler: Handler = .{ .clipboard = .{ .context = &capture, .set = Capture.set } };
    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{ .pane_id = .invalid, .bytes = "hello" }));
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" });
    try std.testing.expectEqualStrings("hello", capture.bytes[0..capture.len]);
    capture.fail = true;
    try std.testing.expectError(error.ClipboardUnavailable, handler.execute(.{ .pane_id = @enumFromInt(1), .bytes = "hello" }));
}
