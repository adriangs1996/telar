const EncodeContext = @This();
const source_namespace = @import("encoder.zig");
const workspace = @import("../../workspace/root.zig");
const history = @import("../../history/root.zig");
buffer: []u8,
panes: *const source_namespace.PaneStore,
workspaces: workspace.Reader,
history_result: *?*history.model.QueryResult,
history_output: *?*history.model.OutputResult,
history_stats: *?*history.model.StatsResult,
