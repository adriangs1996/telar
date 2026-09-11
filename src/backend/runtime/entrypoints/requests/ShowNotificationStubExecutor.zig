const StubExecutor = @This();
const source_namespace = @import("show_notification.zig");
const show_notification_commands = @import("../../application/commands/show_notification.zig");
responses: *source_namespace.ResponseQueue,
delivered_clients: u8,
call_count: usize = 0,
observed_reservation: bool = false,
level: source_namespace.schema.NotificationLevel = .info,
duration_ms: u32 = 0,
target: source_namespace.schema.NotificationTarget = .none,
title: [source_namespace.schema.max_notification_title_bytes]u8 = undefined,
title_len: usize = 0,
message: [source_namespace.schema.max_notification_message_bytes]u8 = undefined,
message_len: usize = 0,

pub fn executor(stub: *StubExecutor) show_notification_commands.ShowNotificationExecutor {
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

pub fn titleSlice(stub: *const StubExecutor) []const u8 {
    return stub.title[0..stub.title_len];
}

pub fn messageSlice(stub: *const StubExecutor) []const u8 {
    return stub.message[0..stub.message_len];
}
