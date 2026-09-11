const PointerPress = @This();
const source_namespace = @import("copy_mode.zig");
pane_id: source_namespace.schema.PaneId,
position: source_namespace.ui.Point,
now_ns: u64,
