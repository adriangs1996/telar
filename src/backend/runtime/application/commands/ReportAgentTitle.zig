const ReportAgentTitle = @This();
const pane_mod = @import("../../../pane/root.zig");
pane: pane_mod.PaneKey,
/// Empty clears an earlier agent title.
title: []const u8,
