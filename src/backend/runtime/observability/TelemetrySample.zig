const Sample = @This();
const source_namespace = @import("telemetry.zig");
const RuntimeMetrics = @import("RuntimeMetrics.zig");
const ClientSample = @import("ClientSample.zig");
const history = @import("../../history/root.zig");
const ProxySample = @import("ProxySample.zig");
io: source_namespace.Io,
metrics: *const RuntimeMetrics,
clients: ClientSample = .{},
workspace_count: usize = 0,
tab_count: usize = 0,
panes: *const source_namespace.PaneStore,
history_service: *const history.Service,
proxy: ProxySample = .{},
heap: *const source_namespace.diagnostics.Heap,
