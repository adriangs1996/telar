const ScheduleArgs = @This();
const source_namespace = @import("config_reload.zig");
const std = @import("std");
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
select: *source_namespace.Io.Select(source_namespace.ClientEvent),
path: []const u8,
profile: ?[]const u8,
trust_path: []const u8,
current_generation: *const lua_config.Generation,
current_registry: *const plugin_broker.Registry,
