const RectType = @import("telar-core").Rect;
const AgentType = @import("telar-client").Agent;
const ColorType = @import("telar-core").Color;
const AgentLocationInput = @This();

area: RectType,
agent: *const AgentType,
pane_index: u16,
background: ColorType,
