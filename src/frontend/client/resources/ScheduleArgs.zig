const std = @import("std");
const Client = @import("../Client.zig");
const GenerationType = @import("../../config/Generation.zig");
const RegistryType = @import("../../plugins/Registry.zig");
const ScheduleArgs = @This();

io: std.Io,
gpa: std.mem.Allocator,
select: *std.Io.Select(Client.ClientEvent),
path: []const u8,
profile: ?[]const u8,
trust_path: []const u8,
current_generation: *const GenerationType,
current_registry: *const RegistryType,
