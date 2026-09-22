const core = @import("telar-core");
const Input = @This();

level: core.NotificationLevel = .info,
duration_ms: u32 = core.default_notification_duration_ms,
target: core.NotificationTarget = .none,
title: []const u8,
message: []const u8,
