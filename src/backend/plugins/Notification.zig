const core = @import("telar-core");
const Notification = @This();

level: core.NotificationLevel,
duration_ms: u32,
title: []const u8,
message: []const u8,
