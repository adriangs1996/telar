/// Stable identity for work that can finish after the pane lifecycle moved
/// on. Generation makes future id reuse safe without changing actor events.
const PaneKey = @This();
const source_namespace = @import("root.zig");
id: source_namespace.schema.PaneId,
generation: u64,
