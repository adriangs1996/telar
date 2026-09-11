const AgentLineInput = @This();
const Input = @import("SidebarInput.zig");
const Semantic = @import("Semantic.zig");
const agents = @import("telar-client").agents;
const ui = @import("../ui/root.zig");
sidebar: Input,
semantic: *Semantic,
y: u16,
agent: *const agents.Agent,
line: u2,
background: ui.Color,
