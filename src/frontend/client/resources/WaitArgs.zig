const WaitArgs = @This();
const source_namespace = @import("config_reload.zig");
const std = @import("std");
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const Orphans = @import("Orphans.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
path: []const u8,
known_mtime_ns: i128,
generation_number: u64,
profile: ?[]const u8,
current_generation: *const lua_config.Generation,
current_registry: *const plugin_broker.Registry,
trust_path: []const u8,
orphans: *Orphans,
