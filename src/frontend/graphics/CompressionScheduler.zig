const Compression = @import("Compression.zig");
const CompressionScheduler = @This();

context: *anyopaque,
start: *const fn (*anyopaque, *Compression) anyerror!void,
