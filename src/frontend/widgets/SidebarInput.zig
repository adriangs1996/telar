const RectType = @import("telar-core").Rect;
const SnapshotType = @import("telar-client").AgentSnapshot;
const State = @import("State.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const AgentKeyType = @import("telar-client").AgentKey;
const Input = @This();

area: RectType,
snapshot: *const SnapshotType,
state: *State,
active_model: ?*const MultiplexerModel = null,
focused_agent: ?AgentKeyType = null,
transparent: bool,
rounded_focus: bool = false,
animation_frame: u8 = 0,
