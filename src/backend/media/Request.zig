const Request = @This();
const core = @import("telar-core");
const std = @import("std");
key: core.graphics.ImageKey,
shared_transport: bool,
allocator: std.mem.Allocator,
