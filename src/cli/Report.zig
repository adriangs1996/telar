const Report = @This();
const source_namespace = @import("hook.zig");
state: source_namespace.schema.AgentReportState,
session: []const u8 = "",
/// Where the agent records its session, when the hook knows it.
session_file: []const u8 = "",
session_file_kind: source_namespace.schema.AgentSessionFileKind = .claude_transcript,
