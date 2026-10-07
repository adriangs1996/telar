const core = @import("telar-core");
const std = @import("std");

key: core.ImageKey,
shared_transport: bool,
allocator: std.mem.Allocator,
