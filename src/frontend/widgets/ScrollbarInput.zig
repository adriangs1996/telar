const core = @import("telar-core");
const State = @import("State.zig");
const ScrollbarInput = @This();

state: *State,
list: core.Rect,
total: u16,
background: core.Color,
