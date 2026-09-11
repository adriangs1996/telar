const Panes = @This();
const source_namespace = @import("open_pane.zig");
const pane_mod = @import("../../../pane/root.zig");
const LaunchPane = @import("OpenPaneLaunchPane.zig");
const PrepareView = @import("PrepareView.zig");
context: *anyopaque,
find: *const fn (*anyopaque, source_namespace.schema.PaneId) ?pane_mod.PaneLaunched,
first: *const fn (*anyopaque, source_namespace.schema.TabLocation) ?pane_mod.PaneLaunched,
launch: *const fn (*anyopaque, LaunchPane) anyerror!pane_mod.PaneLaunched,
prepare_view: *const fn (*anyopaque, PrepareView) anyerror!void,
attach: *const fn (*anyopaque, pane_mod.PaneLaunched) anyerror!void,
