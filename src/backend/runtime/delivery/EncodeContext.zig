const PaneStoreType = @import("../../pane/PaneStore.zig");
const ReaderType = @import("../../workspace/Reader.zig");
const QueryResultType = @import("../../history/QueryResult.zig");
const OutputResultType = @import("../../history/OutputResult.zig");
const StatsResultType = @import("../../history/StatsResult.zig");
const EncodeContext = @This();

buffer: []u8,
panes: *const PaneStoreType,
workspaces: ReaderType,
history_result: *?*QueryResultType,
history_output: *?*OutputResultType,
history_stats: *?*StatsResultType,
