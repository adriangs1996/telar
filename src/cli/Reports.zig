const ReviewHookReport = @import("ReviewHookReport.zig");
const Report = @import("Report.zig");
const CommandReport = @import("CommandReport.zig");
/// Lifecycle, title and command observations plus bounded file evidence and
/// explicitly submitted review feedback for the same provider session.
const Reports = @This();

lifecycle: ?Report = null,
command: ?CommandReport = null,
/// Empty clears an earlier agent title.
title: ?[]const u8 = null,
review: ?ReviewHookReport = null,
