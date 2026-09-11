const HistoryStatsView = @This();
const source_namespace = @import("history.zig");
const HistoryStatsTopIterator = @import("HistoryStatsTopIterator.zig");
request_id: source_namespace.RequestId,
total: u64,
unique: u64,
top_count: u8,
encoded_top: []const u8,

pub fn top(view: HistoryStatsView) HistoryStatsTopIterator {
    return .{ .decoder = .init(view.encoded_top), .remaining = view.top_count };
}
