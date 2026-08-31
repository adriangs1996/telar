//! Request controller for notification broadcast and requester confirmation.

const std = @import("std");
const core = @import("telar-core");
const show_notification_commands = @import("../commands/show_notification.zig");
const delivery_mod = @import("../delivery/root.zig");

const schema = core.schema;
const ResponseQueue = delivery_mod.ResponseQueue;

pub const Delivery = struct {
    context: *anyopaque,
    pump_all_fn: *const fn (*anyopaque) void,

    /// Makes newly queued notifications and confirmation eligible for socket
    /// delivery after their synchronous transaction is complete.
    ///
    /// ```zig
    /// delivery.pumpAll();
    /// ```
    pub fn pumpAll(delivery: Delivery) void {
        delivery.pump_all_fn(delivery.context);
    }
};

pub const Controller = struct {
    responses: *ResponseQueue,
    show_notification: show_notification_commands.ShowNotificationExecutor,
    delivery: Delivery,

    /// Creates one controller scoped to a notification request.
    ///
    /// ```zig
    /// var controller = Controller.init(&responses, handler.executor(), delivery);
    /// ```
    pub fn init(responses: *ResponseQueue, show_notification: show_notification_commands.ShowNotificationExecutor, delivery: Delivery) Controller {
        return .{
            .responses = responses,
            .show_notification = show_notification,
            .delivery = delivery,
        };
    }

    /// Reserves the requester's exact confirmation before broadcasting. Queue
    /// backpressure therefore causes no external effect. On success it commits
    /// the accepted-recipient count and pumps every affected client once.
    ///
    /// ```zig
    /// try controller.showNotification(request);
    /// ```
    pub fn showNotification(controller: *Controller, request: schema.ShowNotification) !void {
        const confirmation = try controller.responses.reserveNotificationShown(request.request_id);
        const result = controller.show_notification.execute(.{
            .notification = request.notification,
        });

        confirmation.delivered_clients = result.delivered_clients;
        controller.delivery.pumpAll();
    }
};

const StubExecutor = struct {
    responses: *ResponseQueue,
    delivered_clients: u8,
    call_count: usize = 0,
    observed_reservation: bool = false,
    level: schema.NotificationLevel = .info,
    duration_ms: u32 = 0,
    target: schema.NotificationTarget = .none,
    title: [schema.max_notification_title_bytes]u8 = undefined,
    title_len: usize = 0,
    message: [schema.max_notification_message_bytes]u8 = undefined,
    message_len: usize = 0,

    fn executor(stub: *StubExecutor) show_notification_commands.ShowNotificationExecutor {
        return .{ .context = stub, .execute_fn = execute };
    }

    fn execute(context: *anyopaque, command: show_notification_commands.ShowNotification) show_notification_commands.ShowNotificationResult {
        const stub: *StubExecutor = @ptrCast(@alignCast(context));
        stub.call_count += 1;
        const response = stub.responses.peek().?;
        stub.observed_reservation = response.* == .notification_shown and
            response.notification_shown.delivered_clients == 0;
        stub.level = command.notification.level;
        stub.duration_ms = command.notification.duration_ms;
        stub.target = command.notification.target;
        stub.title_len = command.notification.title.len;
        @memcpy(stub.title[0..command.notification.title.len], command.notification.title);
        stub.message_len = command.notification.message.len;
        @memcpy(stub.message[0..command.notification.message.len], command.notification.message);
        return .{ .delivered_clients = stub.delivered_clients };
    }

    fn titleSlice(stub: *const StubExecutor) []const u8 {
        return stub.title[0..stub.title_len];
    }

    fn messageSlice(stub: *const StubExecutor) []const u8 {
        return stub.message[0..stub.message_len];
    }
};

const PumpCapture = struct {
    responses: *ResponseQueue,
    expected_delivered: u8,
    call_count: usize = 0,
    observed_committed_confirmation: bool = false,

    fn delivery(capture: *PumpCapture) Delivery {
        return .{ .context = capture, .pump_all_fn = pumpAll };
    }

    fn pumpAll(context: *anyopaque) void {
        const capture: *PumpCapture = @ptrCast(@alignCast(context));
        capture.call_count += 1;
        const response = capture.responses.peek().?;
        capture.observed_committed_confirmation = response.* == .notification_shown and
            response.notification_shown.delivered_clients == capture.expected_delivered;
    }
};

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
