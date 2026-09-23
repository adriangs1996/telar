const std = @import("std");
const Pane = @import("../../pane/Pane.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Preparation = @This();

io: std.Io,
buffer: []u8,
pane: *Pane,
force_snapshot: bool,
metrics: *RuntimeMetrics,
