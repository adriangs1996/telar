//! Vertical tests for notification publication and requester confirmation.

const std = @import("std");
const core = @import("telar-core");
const show_notification_commands = @import("../application/commands/show_notification.zig");
const show_notification_controller = @import("../entrypoints/requests/show_notification.zig");
const delivery_mod = @import("../delivery/root.zig");

pub const schema = core.schema;
pub const PendingNotification = delivery_mod.PendingNotification;
pub const ResponseQueue = delivery_mod.ResponseQueue;

const Broadcaster = @import("ShowNotificationTestBroadcaster.zig");

const PumpCapture = @import("PumpCapture.zig");

fn fill(queue: *ResponseQueue) !void {
    while (queue.len < queue.items.len) {
        try queue.push(.{ .notification_shown = .{
            .request_id = @enumFromInt(queue.len + 1),
            .delivered_clients = 0,
        } });
    }
}

test "show notification confirms only recipients that accepted owned delivery" {
    var requester: ResponseQueue = .{};
    var first: ResponseQueue = .{};
    var saturated: ResponseQueue = .{};
    try fill(&saturated);
    var third: ResponseQueue = .{};
    var broadcaster: Broadcaster = .{ .recipients = .{ &first, &saturated, &third } };
    var handler: show_notification_commands.ShowNotificationHandler = .{
        .notifications = broadcaster.publisher(),
    };
    var pump: PumpCapture = .{};
    var controller = show_notification_controller.Controller.init(
        &requester,
        handler.executor(),
        pump.delivery(),
    );
    var title = [_]u8{ 'B', 'u', 'i', 'l', 'd' };
    var message = [_]u8{ 'D', 'o', 'n', 'e' };
    const request_id: schema.RequestId = @enumFromInt(17);

    try controller.showNotification(.{
        .request_id = request_id,
        .notification = .{
            .level = .success,
            .duration_ms = 2500,
            .target = .{ .pane = try schema.id.pane(42) },
            .title = &title,
            .message = &message,
        },
    });
    @memset(&title, 'x');
    @memset(&message, 'x');

    try std.testing.expectEqual(@as(usize, 1), broadcaster.call_count);
    const confirmation = requester.peek().?.notification_shown;
    try std.testing.expectEqual(request_id, confirmation.request_id);
    try std.testing.expectEqual(@as(u8, 2), confirmation.delivered_clients);
    try std.testing.expectEqual(@as(usize, 1), pump.count);
    try std.testing.expectEqual(@as(u64, 1), saturated.dropped);
    try std.testing.expectEqual(@as(u8, saturated.items.len), saturated.len);

    for ([_]*ResponseQueue{ &first, &third }) |recipient| {
        const notification = recipient.peek().?.notification.view();
        try std.testing.expectEqual(schema.NotificationLevel.success, notification.level);
        try std.testing.expectEqual(@as(u32, 2500), notification.duration_ms);
        try std.testing.expectEqual(try schema.id.pane(42), notification.target.pane);
        try std.testing.expectEqualStrings("Build", notification.title);
        try std.testing.expectEqualStrings("Done", notification.message);
    }
}
