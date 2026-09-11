const std = @import("std");
const schema = @import("telar-core").schema;
const dispatch = @import("root.zig").runtime_messages.dispatch;

pub const Outcome = enum { applied, ignored, exit };
const Capture = @import("Capture.zig");

const Adapter = @import("Adapter.zig");

const VoidAdapter = @import("VoidAdapter.zig");

const Adapters = @import("Adapters.zig");

test "runtime stopping exits without calling slice adapters" {
    var capture: Capture = .{};
    try std.testing.expectEqual(@as(?u8, 0), try dispatch(&capture, .runtime_stopping, Adapters));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "decoded metadata is synchronously delivered without initializing a host" {
    var capture: Capture = .{};
    const message: schema.ServerMessage = .{ .pane_title = .{
        .pane_id = @enumFromInt(1),
        .title = "headless",
    } };
    try std.testing.expect((try dispatch(&capture, message, Adapters)) == null);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}
