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
/// Why the agent is blocked; `none` unless `state` is `blocked`.
blocked_reason: types.AgentBlockedReason = .none,
/// One line describing the reported moment: the pending prompt, the tool
/// call that started, or the result summary. Empty when the hook has none.
event: []const u8 = "",
