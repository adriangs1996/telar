//! Request controller for notification broadcast and requester confirmation.

const std = @import("std");
const core = @import("telar-core");
const show_notification_commands = @import("../../application/commands/show_notification.zig");
const delivery_mod = @import("../../delivery/root.zig");

pub const schema = core.schema;
pub const ResponseQueue = delivery_mod.ResponseQueue;

pub const Delivery = @import("Delivery.zig");

pub const Controller = @import("ShowNotificationController.zig");

const StubExecutor = @import("ShowNotificationStubExecutor.zig");

const PumpCapture = @import("PumpCapture.zig");

test "Controller reserves, broadcasts, commits, then pumps exact notification data" {
    var responses: ResponseQueue = .{};
    var executor: StubExecutor = .{ .responses = &responses, .delivered_clients = 3 };
    var pump: PumpCapture = .{ .responses = &responses, .expected_delivered = 3 };
    var controller = Controller.init(&responses, executor.executor(), pump.delivery());
    const request_id: schema.RequestId = @enumFromInt(7);

    try controller.showNotification(.{
        .request_id = request_id,
        .notification = .{
            .level = .warning,
            .duration_ms = 2500,
            .target = .{ .workspace = try schema.id.workspace(9) },
            .title = "Review",
            .message = "Agent waiting",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), executor.call_count);
    try std.testing.expect(executor.observed_reservation);
    try std.testing.expectEqual(schema.NotificationLevel.warning, executor.level);
    try std.testing.expectEqual(@as(u32, 2500), executor.duration_ms);
    try std.testing.expectEqual(try schema.id.workspace(9), executor.target.workspace);
    try std.testing.expectEqualStrings("Review", executor.titleSlice());
    try std.testing.expectEqualStrings("Agent waiting", executor.messageSlice());
    const confirmation = responses.peek().?.notification_shown;
    try std.testing.expectEqual(request_id, confirmation.request_id);
    try std.testing.expectEqual(@as(u8, 3), confirmation.delivered_clients);
    try std.testing.expectEqual(@as(usize, 1), pump.call_count);
    try std.testing.expect(pump.observed_committed_confirmation);
}

test "Controller confirms and pumps a zero-recipient broadcast" {
    var responses: ResponseQueue = .{};
    var executor: StubExecutor = .{ .responses = &responses, .delivered_clients = 0 };
    var pump: PumpCapture = .{ .responses = &responses, .expected_delivered = 0 };
    var controller = Controller.init(&responses, executor.executor(), pump.delivery());

    try controller.showNotification(.{
        .request_id = @enumFromInt(8),
        .notification = .{ .title = "Nobody" },
    });

    try std.testing.expectEqual(@as(u8, 0), responses.peek().?.notification_shown.delivered_clients);
    try std.testing.expectEqual(@as(usize, 1), executor.call_count);
    try std.testing.expectEqual(@as(usize, 1), pump.call_count);
}

test "Controller queue backpressure prevents broadcast and pumping" {
    var responses: ResponseQueue = .{};
    while (responses.len < responses.items.len) {
        try responses.push(.{ .notification_shown = .{
            .request_id = @enumFromInt(responses.len + 1),
            .delivered_clients = 0,
        } });
    }
    var executor: StubExecutor = .{ .responses = &responses, .delivered_clients = 1 };
    var pump: PumpCapture = .{ .responses = &responses, .expected_delivered = 1 };
    var controller = Controller.init(&responses, executor.executor(), pump.delivery());

    try std.testing.expectError(error.ResponseQueueFull, controller.showNotification(.{
        .request_id = @enumFromInt(99),
        .notification = .{ .title = "Blocked" },
    }));

    try std.testing.expectEqual(@as(usize, 0), executor.call_count);
    try std.testing.expectEqual(@as(usize, 0), pump.call_count);
    try std.testing.expectEqual(@as(u8, responses.items.len), responses.len);
}
