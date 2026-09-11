const Resources = @This();
const source_namespace = @import("observation.zig");
const agent_mod = @import("../../../../agent/root.zig");
io: source_namespace.Io,
panes: *source_namespace.PaneStore,
agents: *agent_mod.Tracker,
metrics: *source_namespace.RuntimeMetrics,
