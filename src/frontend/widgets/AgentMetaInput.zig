const core = @import("telar-core");
const client = @import("telar-client");
const AgentMetaInput = @This();

area: core.Rect,
agent: *const client.Agent,
background: core.Color,
