const std = @import("std");
const RunOptions = @import("arguments/RunOptions.zig");

process: std.process.Init,
options: *const RunOptions,
endpoint: []const u8,
