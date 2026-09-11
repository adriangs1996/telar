const ReportAgentSession = @This();
const pane_mod = @import("../../../pane/root.zig");
pane: pane_mod.PaneKey,
session: []const u8,
now_ms: i64,
