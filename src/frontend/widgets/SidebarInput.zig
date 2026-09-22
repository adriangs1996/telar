const core = @import("telar-core");
const client = @import("telar-client");
const data = @import("model");
const State = @import("State.zig");
const Input = @This();

area: core.Rect,
snapshot: *const data.AgentSnapshot,
state: *State,
active_model: ?*const data.MultiplexerModel = null,
focused_agent: ?data.AgentKey = null,
transparent: bool,
rounded_focus: bool = false,
animation_frame: u8 = 0,
