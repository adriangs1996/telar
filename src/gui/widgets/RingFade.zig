//! One attachment's attention transition; never borrows a pane or model.
const data = @import("model");
const Transition = @import("../animation/Transition.zig");
key: data.AgentKey,
transition: Transition,
