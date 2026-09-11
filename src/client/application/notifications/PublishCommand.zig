const PublishCommand = @This();
const notification_capability = @import("../../root.zig").notifications;
now_ns: u64,
input: notification_capability.Input,
