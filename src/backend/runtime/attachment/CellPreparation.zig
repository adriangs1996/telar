const std = @import("std");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const CellPreparation = @This();

io: std.Io,
buffer: []u8,
metrics: *RuntimeMetricsType,
