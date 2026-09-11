const ResolveArgs = @This();
const std = @import("std");
const source_namespace = @import("config_reload.zig");
const Checks = @import("Checks.zig");
gpa: std.mem.Allocator,
reload: source_namespace.ConfigReload,
checks: Checks,
