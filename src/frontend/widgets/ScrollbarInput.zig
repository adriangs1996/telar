const State = @import("State.zig");
const RectType = @import("telar-core").Rect;
const ColorType = @import("telar-core").Color;
const ScrollbarInput = @This();

state: *State,
list: RectType,
total: u16,
background: ColorType,
