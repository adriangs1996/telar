const Resources = @This();
const source_namespace = @import("proxy_observation.zig");
const agent_mod = @import("../../../agent/root.zig");
panes: *source_namespace.PaneStore,
agents: *agent_mod.Tracker,
metrics: *source_namespace.RuntimeMetrics,
