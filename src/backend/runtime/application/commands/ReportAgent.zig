const PaneKeyType = @import("../../../pane/PaneKey.zig");
const AgentReportStateType = @import("telar-core").AgentReportState;
const SessionFileType = @import("../../../agent/SessionFile.zig");
const ReportAgent = @This();

pane: PaneKeyType,
state: AgentReportStateType,
session: []const u8,
session_file: SessionFileType = .{},
now_ms: i64,
now_ns: ?i64 = null,
