const HookLayout = @import("HookLayout.zig").HookLayout;

events: []const []const u8,
marker: []const u8,
command: []const u8 = "",
timeout_seconds: i64 = 5,
layout: HookLayout = .nested,
