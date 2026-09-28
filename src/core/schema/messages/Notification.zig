const types = @import("../types.zig");
const Notification = @This();

level: types.NotificationLevel = .info,
duration_ms: u32 = types.default_notification_duration_ms,
target: types.NotificationTarget = .none,
title: []const u8,
message: []const u8 = "",
/// An https URL a click on the notification opens; empty for none.
link: []const u8 = "",
