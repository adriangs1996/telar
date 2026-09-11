const ScrollbarInput = @This();
const State = @import("State.zig");
const ui = @import("../ui/root.zig");
state: *State,
list: ui.Rect,
total: u16,
background: ui.Color,
