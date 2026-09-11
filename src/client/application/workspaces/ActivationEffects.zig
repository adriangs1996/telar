const ActivationEffects = @This();
const source_namespace = @import("workspace_transition_delivery.zig");
context: *anyopaque,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
schedule_host_input: *const fn (*anyopaque) anyerror!void,
request_workspace_snapshot: *const fn (*anyopaque, source_namespace.schema.WorkspaceLocation) anyerror!void,
request_tab_snapshot: *const fn (*anyopaque, source_namespace.schema.TabLocation) anyerror!void,
