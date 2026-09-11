const id = @import("../id.zig");
/// Absolute scrollback row to place at the top of one client attachment.
const SetPaneViewport = @This();

pane_id: id.PaneId,
offset: u32,
