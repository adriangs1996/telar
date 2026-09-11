const HistoryStats = @This();
const source_namespace = @import("history.zig");
const HistoryStatsTop = @import("HistoryStatsTop.zig");
request_id: source_namespace.RequestId,
total: u64,
unique: u64,
top: []const HistoryStatsTop,
