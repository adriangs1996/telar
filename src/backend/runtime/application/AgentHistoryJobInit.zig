const ClientKey = @import("../../history/ClientKey.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const core = @import("telar-core");

client: ClientKey,
pane: PaneKey,
thread_id: []const u8,
options: *@import("../../agent_panes/HistoryOptions.zig"),
request: core.QueryAgentHistory,
