/// Absolute scrollback row to place at the top of one client attachment.
const SetPaneViewport = @This();
const source_namespace = @import("pane.zig");
pane_id: source_namespace.PaneId,
offset: u32,
