const ImageKeyType = @import("telar-core").ImageKey;
const std = @import("std");
const Request = @This();

key: ImageKeyType,
shared_transport: bool,
allocator: std.mem.Allocator,
