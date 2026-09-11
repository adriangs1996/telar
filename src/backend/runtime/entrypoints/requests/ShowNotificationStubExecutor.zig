const ResponseQueueType = @import("../../delivery/ResponseQueue.zig");
const NotificationLevelType = @import("telar-core").NotificationLevel;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const max_notification_title_bytes_module = @import("telar-core").max_notification_title_bytes;
const max_notification_message_bytes_module = @import("telar-core").max_notification_message_bytes;
const ShowNotificationExecutorType = @import("../../application/commands/ShowNotificationExecutor.zig");
const ShowNotificationType = @import("../../application/commands/ShowNotification.zig");
const ShowNotificationResultType = @import("../../application/commands/ShowNotificationResult.zig");
const StubExecutor = @This();

responses: *ResponseQueueType,
delivered_clients: u8,
call_count: usize = 0,
observed_reservation: bool = false,
level: NotificationLevelType = .info,
duration_ms: u32 = 0,
target: NotificationTargetType = .none,
title: [max_notification_title_bytes_module]u8 = undefined,
title_len: usize = 0,
message: [max_notification_message_bytes_module]u8 = undefined,
message_len: usize = 0,

pub fn executor(stub: *StubExecutor) ShowNotificationExecutorType {
    return .{ .context = stub, .execute_fn = execute };
}

fn execute(context: *anyopaque, command: ShowNotificationType) ShowNotificationResultType {
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

pub fn titleSlice(stub: *const StubExecutor) []const u8 {
    return stub.title[0..stub.title_len];
}

pub fn messageSlice(stub: *const StubExecutor) []const u8 {
    return stub.message[0..stub.message_len];
}
