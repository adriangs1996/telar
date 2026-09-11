const AgentStatusInput = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("sidebar.zig");
area: ui.Rect,
status: source_namespace.schema.AgentStatus,
animation_frame: u8,
background: ui.Color,
