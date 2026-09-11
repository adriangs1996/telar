const std = @import("std");
/// Process facilities selected by `main` and borrowed by one runtime instance.
const Dependencies = @This();

io: std.Io,
allocator: std.mem.Allocator,
