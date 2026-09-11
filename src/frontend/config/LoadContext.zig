const LoadContext = @This();
const std = @import("std");
const source_namespace = @import("generation_support.zig");
gpa: std.mem.Allocator,
io: source_namespace.Io,
diagnostic: *source_namespace.Diagnostic,
