const ExecutionResources = @This();
const source_namespace = @import("main.zig");
const std = @import("std");
io: source_namespace.Io,
gpa: std.mem.Allocator,
