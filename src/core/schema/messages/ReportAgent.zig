const id = @import("../id.zig");
const types = @import("../types.zig");
/// An official lifecycle report from an agent's hooks: its state and,
/// optionally, its own session reference and the file it records the session
/// in. Only the exact pane generation that hosts the agent accepts it.
const ReportAgent = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
state: types.AgentReportState,
session: []const u8 = "",
session_file: []const u8 = "",
session_file_kind: types.AgentSessionFileKind = .claude_transcript,
