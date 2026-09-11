/// Process facilities selected by `main` and borrowed by one runtime instance.
const Dependencies = @This();
const source_namespace = @import("config.zig");
const std = @import("std");
io: source_namespace.Io,
allocator: std.mem.Allocator,
