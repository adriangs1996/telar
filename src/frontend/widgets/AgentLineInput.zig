const client = @import("telar-client");
const core = @import("telar-core");
const SidebarInput = @import("SidebarInput.zig");
const Semantic = @import("Semantic.zig");
const AgentLineInput = @This();

sidebar: SidebarInput,
semantic: *Semantic,
y: u16,
agent: *const client.Agent,
line: u2,
background: core.Color,
