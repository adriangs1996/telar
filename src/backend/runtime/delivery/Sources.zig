const core = @import("telar-core");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const SamplerType = @import("../observability/Sampler.zig");
const StoreType = @import("../application/Store.zig");
const Sources = @This();

panes: *const PaneStoreType,
workspaces: *const Workspaces,
agents: *const TrackerType,
manifests: *const core.Table = &core.builtin_table,
system_metrics: *const SamplerType,
proxy_active: bool,
proxy_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
home: ?[]const u8,
client_layouts: ?*StoreType = null,
/// Wall clock at preparation time; dates agent status ages.
now_ms: i64 = 0,
/// The agent snapshot revision clients compare against what they received.
agent_revision: u64 = 0,
/// The enriched agent snapshot, built once per flush when a client sends it.
agent_entries: []const core.AgentSnapshotEntry = &.{},
