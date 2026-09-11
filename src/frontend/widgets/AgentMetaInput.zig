const RectType = @import("telar-core").Rect;
const AgentType = @import("telar-client").Agent;
const ColorType = @import("telar-core").Color;
const AgentMetaInput = @This();

area: RectType,
agent: *const AgentType,
background: ColorType,
