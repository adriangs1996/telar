const std = @import("std");
const InitOptions = @This();

io: std.Io,
allocator: std.mem.Allocator,
rows: u16,
cols: u16,
