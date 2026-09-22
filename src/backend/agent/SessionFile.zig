const core = @import("telar-core");
/// One official lifecycle report from the agent's own hooks.
/// The file an agent records its session in, as reported by its hooks.
const SessionFile = @This();

kind: core.AgentSessionFileKind = .claude_transcript,
path: []const u8 = "",
