const ReportedPaneFocus = @import("ReportedPaneFocus.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneFocusReportTransition = @This();

previous: ?ReportedPaneFocus,
current: ?ReportedPaneFocus,
focus_out: ?PaneIdType = null,
focus_in: ?PaneIdType = null,
