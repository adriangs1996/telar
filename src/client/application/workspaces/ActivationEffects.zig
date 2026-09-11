const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabLocationType = @import("telar-core").TabLocation;
const ActivationEffects = @This();

context: *anyopaque,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
schedule_host_input: *const fn (*anyopaque) anyerror!void,
request_workspace_snapshot: *const fn (*anyopaque, WorkspaceLocationType) anyerror!void,
request_tab_snapshot: *const fn (*anyopaque, TabLocationType) anyerror!void,
