const std = @import("std");
const RemovalResources = @This();

io: std.Io,
gpa: std.mem.Allocator,
