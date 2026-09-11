const PaneExited = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
kind: source_namespace.ExitKind,
value: u32,
