const AgentMetaInput = @This();
const ui = @import("../ui/root.zig");
const agents = @import("telar-client").agents;
area: ui.Rect,
agent: *const agents.Agent,
background: ui.Color,
