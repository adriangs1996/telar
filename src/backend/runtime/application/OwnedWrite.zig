const std = @import("std");
const WriteJob = @import("WriteJob.zig");
const OwnedWrite = @This();

allocator: std.mem.Allocator,
job: WriteJob,
