const std = @import("std");
const ExecutionResources = @This();

io: std.Io,
gpa: std.mem.Allocator,
