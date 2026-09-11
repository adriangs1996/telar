const PaneFocusReportTransition = @This();
const ReportedPaneFocus = @import("ReportedPaneFocus.zig");
const source_namespace = @import("types.zig");
previous: ?ReportedPaneFocus,
current: ?ReportedPaneFocus,
focus_out: ?source_namespace.schema.PaneId = null,
focus_in: ?source_namespace.schema.PaneId = null,
