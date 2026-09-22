const core = @import("telar-core");
const client = @import("telar-client");
const AgentLocationInput = @This();

area: core.Rect,
agent: *const client.Agent,
pane_index: u16,
background: core.Color,
