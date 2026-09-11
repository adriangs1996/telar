/// An official lifecycle report from an agent's hooks: its state and,
/// optionally, its own session reference and the file it records the session
/// in. Only the exact pane generation that hosts the agent accepts it.
const ReportAgent = @This();
const source_namespace = @import("agent.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
state: source_namespace.AgentReportState,
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: source_namespace.AgentSessionFileKind = .claude_transcript,
