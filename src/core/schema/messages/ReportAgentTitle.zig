/// The name an agent's own session carries, reported by its hooks when the
/// user renames it inside the agent. An empty title clears an earlier agent
/// title. Only the exact pane generation that hosts the agent accepts it.
const ReportAgentTitle = @This();
const source_namespace = @import("agent.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
pane_generation: u64,
title: []const u8 = "",
