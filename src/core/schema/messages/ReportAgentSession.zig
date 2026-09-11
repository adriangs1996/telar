/// An agent's own session identifier, reported by its lifecycle hooks so a
/// restart can resume the conversation. Only the exact pane generation that
/// hosts the agent accepts it.
const ReportAgentSession = @This();
const source_namespace = @import("agent.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
session: []const u8,
