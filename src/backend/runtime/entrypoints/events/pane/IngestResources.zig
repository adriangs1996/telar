const Resources = @This();
const source_namespace = @import("ingest.zig");
io: source_namespace.Io,
panes: *source_namespace.PaneStore,
metrics: *source_namespace.RuntimeMetrics,
