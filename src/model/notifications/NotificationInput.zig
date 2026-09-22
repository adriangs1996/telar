const notifications = @import("notifications.zig");
const Input = @This();

level: notifications.Level = .info,
title: []const u8,
message: []const u8,
target: notifications.Target = .none,
duration_ns: u64 = notifications.default_duration_ns,
