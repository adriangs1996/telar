const NotificationLevelType = @import("telar-core").NotificationLevel;
const default_notification_duration_ms_module = @import("telar-core").default_notification_duration_ms;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const Input = @This();

level: NotificationLevelType = .info,
duration_ms: u32 = default_notification_duration_ms_module,
target: NotificationTargetType = .none,
title: []const u8,
message: []const u8,
