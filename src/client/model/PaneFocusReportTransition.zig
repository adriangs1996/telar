const core = @import("telar-core");
const ReportedPaneFocus = @import("ReportedPaneFocus.zig");
const PaneFocusReportTransition = @This();

previous: ?ReportedPaneFocus,
current: ?ReportedPaneFocus,
focus_out: ?core.PaneId = null,
focus_in: ?core.PaneId = null,
