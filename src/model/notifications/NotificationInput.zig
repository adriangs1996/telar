const notifications = @import("notifications.zig");
const Input = @This();

level: notifications.Level = .info,
title: []const u8,
message: []const u8,
/// An https URL a click opens, already validated by the wire; empty for none.
link: []const u8 = "",
target: notifications.Target = .none,
duration_ns: u64 = notifications.default_duration_ns,
