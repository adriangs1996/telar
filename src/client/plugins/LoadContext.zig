const std = @import("std");
const LoadContext = @This();

gpa: std.mem.Allocator,
io: std.Io,
config_dir: []const u8,
