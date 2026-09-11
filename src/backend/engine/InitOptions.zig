const std = @import("std");
const InitOptions = @This();

allocator: std.mem.Allocator,
io: std.Io,
stdout: std.Io.File,
