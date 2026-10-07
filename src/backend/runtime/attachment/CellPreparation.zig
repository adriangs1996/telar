const std = @import("std");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");

io: std.Io,
buffer: []u8,
metrics: *RuntimeMetrics,
