//! The pane an attention ring surrounds, its status colour source and how it moves.
const data = @import("model");
const core = @import("telar-core");
view: data.LayoutView,
status: core.AgentStatus,
key: data.AgentKey,
