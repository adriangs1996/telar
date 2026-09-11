const Capture = @import("Capture.zig");
const std = @import("std");
const runtime_messages_module = @import("runtime_messages.zig");
const Adapters = @import("Adapters.zig");
const ServerMessageType = @import("telar-core").ServerMessage;

pub const Outcome = enum { applied, ignored, exit };

test "runtime stopping exits without calling slice adapters" {
    var capture: Capture = .{};
    try std.testing.expectEqual(@as(?u8, 0), try runtime_messages_module.dispatch(&capture, .runtime_stopping, Adapters));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "decoded metadata is synchronously delivered without initializing a host" {
    var capture: Capture = .{};
    const message: ServerMessageType = .{ .pane_title = .{
        .pane_id = @enumFromInt(1),
        .title = "headless",
    } };
    try std.testing.expect((try runtime_messages_module.dispatch(&capture, message, Adapters)) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
