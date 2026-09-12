const std = @import("std");
const config_reload = @import("config_reload.zig");
const Checks = @import("Checks.zig");
const ResolveArgs = @This();

gpa: std.mem.Allocator,
reload: config_reload.ConfigReload,
checks: Checks,
