const Resources = @This();
const source_namespace = @import("ca.zig");
const std = @import("std");
io: source_namespace.Io,
allocator: std.mem.Allocator,
