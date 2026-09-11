const std = @import("std");
const Resources = @This();

io: std.Io,
allocator: std.mem.Allocator,
