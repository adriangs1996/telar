const LoadContext = @This();
const std = @import("std");
const source_namespace = @import("root.zig");
gpa: std.mem.Allocator,
io: source_namespace.Io,
config_dir: []const u8,
