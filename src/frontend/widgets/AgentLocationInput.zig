const AgentLocationInput = @This();
const ui = @import("../ui/root.zig");
const agents = @import("telar-client").agents;
area: ui.Rect,
agent: *const agents.Agent,
pane_index: u16,
background: ui.Color,
