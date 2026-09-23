const ReviewResult = @import("../../change_review/Result.zig");
const PaneStore = @import("../../pane/PaneStore.zig");
const Workspaces = @import("../../workspace/Workspaces.zig");
const QueryResult = @import("../../history/QueryResult.zig");
const OutputResult = @import("../../history/OutputResult.zig");
const StatsResult = @import("../../history/StatsResult.zig");
const EncodeContext = @This();

buffer: []u8,
panes: *const PaneStore,
workspaces: *const Workspaces,
history_result: *?*QueryResult,
history_output: *?*OutputResult,
history_stats: *?*StatsResult,
agent_history: ?*?*@import("OwnedAgentHistoryPage.zig") = null,

change_review: ?*?*ReviewResult = null,
