const Input = @This();
const ui = @import("../ui/root.zig");
const source_namespace = @import("sidebar.zig");
const State = @import("State.zig");
area: ui.Rect,
snapshot: *const source_namespace.Snapshot,
state: *State,
active_model: ?*const source_namespace.multiplexer.Model = null,
focused_agent: ?source_namespace.AgentKey = null,
transparent: bool,
rounded_focus: bool = false,
animation_frame: u8 = 0,
