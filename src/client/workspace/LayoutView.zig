const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const View = @This();

pane_id: PaneIdType,
outer: RectType,
content: RectType,
focused: bool,
/// One-based tiled position, the same number `Layout.displayIndex`
/// returns. Fullscreen keeps the pane's tiled number instead of restarting
/// at one.
display_index: u16,
