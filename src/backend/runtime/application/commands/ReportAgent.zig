const core = @import("telar-core");
const PaneKeyType = @import("../../../pane/PaneKey.zig");
const SessionFileType = @import("../../../agent/SessionFile.zig");
const ReportAgent = @This();

pane: PaneKeyType,
state: core.AgentReportState,
blocked_reason: core.AgentBlockedReason = .none,
event: []const u8 = "",
session: []const u8,
session_file: SessionFileType = .{},
now_ms: i64,
now_ns: ?i64 = null,
