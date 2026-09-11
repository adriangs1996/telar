const CompressionScheduler = @This();
const Compression = @import("Compression.zig");
context: *anyopaque,
start: *const fn (*anyopaque, *Compression) anyerror!void,
