const Preparation = @This();
const source_namespace = @import("cell.zig");
io: source_namespace.Io,
buffer: []u8,
pane: *source_namespace.Pane,
force_snapshot: bool,
metrics: *source_namespace.RuntimeMetrics,
