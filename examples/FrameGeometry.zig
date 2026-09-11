const FrameGeometry = @This();
const source_namespace = @import("terminal_browser_pane.zig");
/// Exactly half of the host in both dimensions, rounded down.
outer: source_namespace.ui.Rect,
/// The PTY geometry after reserving a one-cell border.
content: source_namespace.ui.Rect,
