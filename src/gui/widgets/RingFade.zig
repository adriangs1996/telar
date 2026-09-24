//! One attachment's attention transition; never borrows a pane or model.
const data = @import("model");
const animate = @import("animate");
const Transition = animate.Transition;
key: data.AgentKey,
transition: Transition,
