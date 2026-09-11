const OwnedWrite = @This();
const std = @import("std");
const WriteJob = @import("WriteJob.zig");
allocator: std.mem.Allocator,
job: WriteJob,
