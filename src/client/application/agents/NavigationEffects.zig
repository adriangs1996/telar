const NavigationEffects = @This();
const source_namespace = @import("agent_navigation.zig");
const client_model = @import("../../root.zig").model;
context: *anyopaque,
select_tab: *const fn (*anyopaque, source_namespace.schema.TabId) anyerror!bool,
focus_pane: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
request_handoff: *const fn (*anyopaque, client_model.AgentHandoff) anyerror!void,
