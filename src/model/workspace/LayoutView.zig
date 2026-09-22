const core = @import("telar-core");
const View = @This();

pane_id: core.PaneId,
surface: core.PaneSurface = .terminal,
outer: core.Rect,
content: core.Rect,
focused: bool,
/// One-based tiled position, the same number `Layout.displayIndex`
/// returns. Fullscreen keeps the pane's tiled number instead of restarting
/// at one.
display_index: u16,
