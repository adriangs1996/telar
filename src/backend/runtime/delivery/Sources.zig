const Sources = @This();
const source_namespace = @import("root.zig");
const workspace_mod = @import("../../workspace/root.zig");
const agent_mod = @import("../../agent/root.zig");
const core = @import("telar-core");
const system_metrics_mod = @import("../observability/root.zig").system_metrics;
const client_layout_store = @import("../application/client_layout_store.zig");
panes: *const source_namespace.PaneStore,
workspaces: workspace_mod.Reader,
agents: *const agent_mod.Tracker,
manifests: *const core.agent_manifest.Table = &core.agent_manifest.builtin_table,
system_metrics: *const system_metrics_mod.Sampler,
proxy_active: bool,
proxy_scope: source_namespace.schema.ProxyScope = .exact,
proxy_system_trusted: bool = false,
home: ?[]const u8,
client_layouts: ?*client_layout_store.Store = null,
