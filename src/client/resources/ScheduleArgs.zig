const std = @import("std");
const Workers = @import("../execution/Workers.zig");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const ScheduleArgs = @This();

io: std.Io,
gpa: std.mem.Allocator,
workers: Workers,
path: []const u8,
profile: ?[]const u8,
trust_path: []const u8,
current_generation: *const GenerationType,
current_registry: *const RegistryType,
