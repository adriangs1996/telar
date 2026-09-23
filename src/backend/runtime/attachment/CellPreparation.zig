const std = @import("std");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const CellPreparation = @This();

io: std.Io,
buffer: []u8,
metrics: *RuntimeMetrics,
