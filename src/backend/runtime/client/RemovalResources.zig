const RemovalResources = @This();
const source_namespace = @import("store_support.zig");
const std = @import("std");
io: source_namespace.Io,
gpa: std.mem.Allocator,
