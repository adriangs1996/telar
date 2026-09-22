//! One attachment's attention transition; never borrows a pane or model.
const data = @import("model");
key: data.AgentKey,
transition: @import("../animation/Transition.zig"),
