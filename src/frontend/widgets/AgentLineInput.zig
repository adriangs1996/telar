const SidebarInput = @import("SidebarInput.zig");
const Semantic = @import("Semantic.zig");
const AgentType = @import("telar-client").Agent;
const ColorType = @import("telar-core").Color;
const AgentLineInput = @This();

sidebar: SidebarInput,
semantic: *Semantic,
y: u16,
agent: *const AgentType,
line: u2,
background: ColorType,
