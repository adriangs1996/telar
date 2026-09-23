const PluginOverrides = @import("PluginOverrides.zig");
const std = @import("std");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");
const Orphans = @import("Orphans.zig");
const WaitArgs = @This();

io: std.Io,
gpa: std.mem.Allocator,
path: []const u8,
known_mtime_ns: i128,
force_reload: bool = false,
plugin_overrides: PluginOverrides = .{},
generation_number: u64,
profile: ?[]const u8,
current_generation: *const Generation,
current_registry: *const Registry,
trust_path: []const u8,
orphans: *Orphans,
