const std = @import("std");
const RunOptions = @import("arguments/RunOptions.zig");
const Preparation = @This();

process: std.process.Init,
options: *const RunOptions,
endpoint: []const u8,
