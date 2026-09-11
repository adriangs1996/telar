/// Everything one hook invocation may send: at most one lifecycle report,
/// one command report and one title report.
const Reports = @This();
const Report = @import("Report.zig");
const CommandReport = @import("CommandReport.zig");
lifecycle: ?Report = null,
command: ?CommandReport = null,
/// Empty clears an earlier agent title.
title: ?[]const u8 = null,
