const id = @import("../id.zig");
const HistoryStatsTopIterator = @import("HistoryStatsTopIterator.zig");
const HistoryStatsView = @This();

request_id: id.RequestId,
total: u64,
unique: u64,
top_count: u8,
encoded_top: []const u8,

pub fn top(self: HistoryStatsView) HistoryStatsTopIterator {
    return .{ .decoder = .init(self.encoded_top), .remaining = self.top_count };
}
