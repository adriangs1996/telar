const ReviewResult = @import("../../change_review/Result.zig");
const PaneStoreType = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const QueryResultType = @import("../../history/QueryResult.zig");
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const EncodeContext = @This();

buffer: []u8,
panes: *const PaneStoreType,
workspaces: *const Workspaces,
history_result: *?*QueryResultType,
history_output: *?*OutputResultType,
history_stats: *?*StatsResultType,
agent_history: ?*?*@import("OwnedAgentHistoryPage.zig") = null,

change_review: ?*?*ReviewResult = null,
