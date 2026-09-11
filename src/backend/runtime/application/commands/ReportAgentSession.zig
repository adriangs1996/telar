const PaneKeyType = @import("../../../pane/PaneKey.zig");
const ReportAgentSession = @This();

pane: PaneKeyType,
session: []const u8,
now_ms: i64,
