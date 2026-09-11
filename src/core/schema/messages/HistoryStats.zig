const id = @import("../id.zig");
const HistoryStatsTop = @import("HistoryStatsTop.zig");
const HistoryStats = @This();

request_id: id.RequestId,
total: u64,
unique: u64,
top: []const HistoryStatsTop,
