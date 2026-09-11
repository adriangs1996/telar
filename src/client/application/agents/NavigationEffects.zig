const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const AgentHandoffType = @import("../../model/AgentHandoff.zig");
const NavigationEffects = @This();

context: *anyopaque,
select_tab: *const fn (*anyopaque, TabIdType) anyerror!bool,
focus_pane: *const fn (*anyopaque, PaneIdType) anyerror!void,
request_handoff: *const fn (*anyopaque, AgentHandoffType) anyerror!void,
