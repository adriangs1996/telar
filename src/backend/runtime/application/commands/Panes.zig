const PaneIdType = @import("telar-core").PaneId;
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const TabLocationType = @import("telar-core").TabLocation;
const OpenPaneLaunchPane = @import("OpenPaneLaunchPane.zig");
const PrepareView = @import("PrepareView.zig");
const Panes = @This();

context: *anyopaque,
find: *const fn (*anyopaque, PaneIdType) ?PaneLaunchedType,
first: *const fn (*anyopaque, TabLocationType) ?PaneLaunchedType,
launch: *const fn (*anyopaque, OpenPaneLaunchPane) anyerror!PaneLaunchedType,
prepare_view: *const fn (*anyopaque, PrepareView) anyerror!void,
attach: *const fn (*anyopaque, PaneLaunchedType) anyerror!void,
