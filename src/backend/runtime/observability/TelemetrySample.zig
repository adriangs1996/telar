const std = @import("std");
const RuntimeMetrics = @import("RuntimeMetrics.zig");
const ClientSample = @import("ClientSample.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const ServiceType = @import("../../history/Service.zig");
const ProxySample = @import("ProxySample.zig");
const HeapType = @import("telar-core").Heap;
const Sample = @This();

io: std.Io,
metrics: *const RuntimeMetrics,
clients: ClientSample = .{},
workspace_count: usize = 0,
tab_count: usize = 0,
panes: *const PaneStoreType,
history_service: *const ServiceType,
proxy: ProxySample = .{},
heap: *const HeapType,
