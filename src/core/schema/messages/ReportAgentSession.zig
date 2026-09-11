const id = @import("../id.zig");
/// An agent's own session identifier, reported by its lifecycle hooks so a
/// restart can resume the conversation. Only the exact pane generation that
/// hosts the agent accepts it.
const ReportAgentSession = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
session: []const u8,
