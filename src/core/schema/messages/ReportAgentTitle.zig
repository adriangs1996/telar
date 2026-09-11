const id = @import("../id.zig");
/// The name an agent's own session carries, reported by its hooks when the
/// user renames it inside the agent. An empty title clears an earlier agent
/// title. Only the exact pane generation that hosts the agent accepts it.
const ReportAgentTitle = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
title: []const u8 = "",
