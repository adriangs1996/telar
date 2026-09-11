const PaneStoreType = @import("../../pane/PaneStore.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const SamplerType = @import("../observability/Sampler.zig");
const ProxyScopeType = @import("telar-core").ProxyScope;
const StoreType = @import("../application/Store.zig");
const Sources = @This();

panes: *const PaneStoreType,
workspaces: ReaderType,
agents: *const TrackerType,
manifests: *const TableType = &builtin_table_module,
system_metrics: *const SamplerType,
proxy_active: bool,
proxy_scope: ProxyScopeType = .exact,
proxy_system_trusted: bool = false,
home: ?[]const u8,
client_layouts: ?*StoreType = null,
