const std = @import("std");
const Workers = @import("../execution/Workers.zig");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");
const ScheduleArgs = @This();

io: std.Io,
gpa: std.mem.Allocator,
workers: Workers,
path: []const u8,
profile: ?[]const u8,
trust_path: []const u8,
current_generation: *const Generation,
current_registry: *const Registry,
