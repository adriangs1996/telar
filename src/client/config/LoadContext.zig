const data = @import("model");
const std = @import("std");
const LoadContext = @This();

gpa: std.mem.Allocator,
io: std.Io,
diagnostic: *data.Diagnostic,
