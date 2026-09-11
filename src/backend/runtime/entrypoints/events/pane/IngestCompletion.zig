const Completion = @This();
const source_namespace = @import("ingest.zig");
pane: source_namespace.PaneKey,
result: anyerror!source_namespace.Stats,
