const std = @import("std");
const ConfigReloadWatcher = @import("ConfigReloadWatcher.zig");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const ScheduleArgs = @This();

io: std.Io,
gpa: std.mem.Allocator,
watcher: ConfigReloadWatcher,
path: []const u8,
profile: ?[]const u8,
trust_path: []const u8,
current_generation: *const GenerationType,
current_registry: *const RegistryType,
