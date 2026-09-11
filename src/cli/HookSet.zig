const HookSet = @This();

events: []const []const u8,
marker: []const u8,
command: []const u8 = "",
timeout_seconds: i64 = 5,
