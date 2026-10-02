const Report = @import("Report.zig");
const CommandReport = @import("CommandReport.zig");
const core = @import("telar-core");
/// Lifecycle, title, command and progress observations for one provider session.
const Reports = @This();

lifecycle: ?Report = null,
command: ?CommandReport = null,
/// Empty clears an earlier agent title.
title: ?[]const u8 = null,
/// Working directory, plan change and final answer; request and pane
/// fields are filled when sent.
progress: ?core.ReportAgentProgress = null,
/// A limit the hook input reached: the reports above hold what fit.
limit: ?core.LimitReach = null,
