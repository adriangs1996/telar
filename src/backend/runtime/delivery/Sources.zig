const core = @import("telar-core");
const PaneStore = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const Worktrees = @import("../../workspace/Worktrees.zig");
const Agents = @import("../../agent/Agents.zig");
const hostmetrics = @import("hostmetrics");
const Sampler = hostmetrics.Sampler;
const ClientLayouts = @import("../ClientLayouts.zig");
const Sources = @This();

const no_worktrees: Worktrees = .{};

panes: *const PaneStore,
workspaces: *const Workspaces,
worktrees: *const Worktrees = &no_worktrees,
agents: *const Agents,
manifests: *const core.Table = &core.builtin_table,
system_metrics: *const Sampler,
proxy_active: bool,
proxy_scope: core.ProxyScope = .exact,
proxy_system_trusted: bool = false,
/// The port the active proxy listens on; null while it is disabled.
proxy_port: ?u16 = null,
/// The port the active proxy tried first; null when it remembered none.
proxy_preferred_port: ?u16 = null,
home: ?[]const u8,
client_layouts: ?*ClientLayouts = null,
/// Wall clock at preparation time; dates agent status ages.
now_ms: i64 = 0,
/// The agent snapshot revision clients compare against what they received.
agent_revision: u64 = 0,
/// The enriched agent snapshot, built once per flush when a client sends it.
agent_entries: []const core.AgentSnapshotEntry = &.{},
/// The limit registry `limit_list` replies are encoded from.
runtime_limits: *const core.LimitReaches = &core.LimitReaches.none,
client_limits: *const core.LimitReaches = &core.LimitReaches.none,
refused_limit_reports: u64 = 0,
