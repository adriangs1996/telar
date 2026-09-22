const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const AgentMetaInput = @This();

area: core.Rect,
agent: *const data.Agent,
background: core.Color,
