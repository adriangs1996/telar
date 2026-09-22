const core = @import("telar-core");
const std = @import("std");
const Request = @This();

key: core.ImageKey,
shared_transport: bool,
allocator: std.mem.Allocator,
