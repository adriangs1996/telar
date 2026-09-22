const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const AgentLocationInput = @This();

area: core.Rect,
agent: *const data.Agent,
pane_index: u16,
background: core.Color,
