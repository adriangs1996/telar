const std = @import("std");

allocator: std.mem.Allocator,
io: std.Io,
stdout: std.Io.File,
