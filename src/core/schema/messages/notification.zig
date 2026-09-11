const Notification = @This();
const source_namespace = @import("notification_support.zig");
const types = @import("../types.zig");
level: source_namespace.NotificationLevel = .info,
duration_ms: u32 = types.default_notification_duration_ms,
target: source_namespace.NotificationTarget = .none,
title: []const u8,
message: []const u8 = "",
