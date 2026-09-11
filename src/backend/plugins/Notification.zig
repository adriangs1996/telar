const NotificationLevelType = @import("telar-core").NotificationLevel;
const Notification = @This();

level: NotificationLevelType,
duration_ms: u32,
title: []const u8,
message: []const u8,
