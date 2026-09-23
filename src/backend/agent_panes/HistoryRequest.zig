const core = @import("telar-core");
const HistoryOptions = @import("HistoryOptions.zig");
options: *const HistoryOptions,
query: core.QueryAgentHistory,
thread_id: []const u8,
