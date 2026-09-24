const core = @import("telar-core");
const PaneStore = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const Tracker = @import("../../agent/Tracker.zig");
const hostmetrics = @import("hostmetrics");
const Sampler = hostmetrics.Sampler;
const ClientLayouts = @import("../ClientLayouts.zig");
const Sources = @This();

panes: *const PaneStore,
workspaces: *const Workspaces,
agents: *const Tracker,
manifests: *const core.Table = &core.builtin_table,
system_metrics: *const Sampler,
proxy_active: bool,
proxy_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
home: ?[]const u8,
client_layouts: ?*ClientLayouts = null,
/// Wall clock at preparation time; dates agent status ages.
now_ms: i64 = 0,
/// The agent snapshot revision clients compare against what they received.
agent_revision: u64 = 0,
/// The enriched agent snapshot, built once per flush when a client sends it.
agent_entries: []const core.AgentSnapshotEntry = &.{},
