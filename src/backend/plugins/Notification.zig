const Notification = @This();
const core = @import("telar-core");
level: core.schema.NotificationLevel,
duration_ms: u32,
title: []const u8,
message: []const u8,
