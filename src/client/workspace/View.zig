const View = @This();
const source_namespace = @import("layout_support.zig");
pane_id: source_namespace.schema.PaneId,
outer: source_namespace.ui.Rect,
content: source_namespace.ui.Rect,
focused: bool,
/// One-based tiled position, the same number `Layout.displayIndex`
/// returns. Fullscreen keeps the pane's tiled number instead of restarting
/// at one.
display_index: u16,
