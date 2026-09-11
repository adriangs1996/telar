const Resources = @This();
const agent_mod = @import("../../../agent/root.zig");
const State = @import("State.zig");
const source_namespace = @import("agent_description.zig");
agents: *agent_mod.Tracker,
state: *State,
command: ?source_namespace.description.Command,
