/// One official lifecycle report from the agent's own hooks.
/// The file an agent records its session in, as reported by its hooks.
const SessionFile = @This();
const source_namespace = @import("types.zig");
kind: source_namespace.schema.AgentSessionFileKind = .claude_transcript,
path: []const u8 = "",
