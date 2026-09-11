const PaintedLabel = @This();
const source_namespace = @import("pane_labels.zig");
buffer: *const source_namespace.ui.Buffer,
area: source_namespace.ui.Rect,
selected: bool,
