const RectType = @import("telar-core").Rect;
const AgentStatusType = @import("telar-core").AgentStatus;
const ColorType = @import("telar-core").Color;
const AgentStatusInput = @This();

area: RectType,
status: AgentStatusType,
animation_frame: u8,
background: ColorType,
