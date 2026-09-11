const PaneIdType = @import("telar-core").PaneId;
const pane_focus_reporting = @import("pane_focus_reporting.zig");
const Delivery = @This();

pane_id: PaneIdType,
direction: pane_focus_reporting.Direction,
