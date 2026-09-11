const ReportAgent = @This();
const pane_mod = @import("../../../pane/root.zig");
const source_namespace = @import("report_agent.zig");
const agent_mod = @import("../../../agent/root.zig");
pane: pane_mod.PaneKey,
state: source_namespace.schema.AgentReportState,
session: []const u8,
session_file: agent_mod.SessionFile = .{},
now_ms: i64,
now_ns: ?i64 = null,
