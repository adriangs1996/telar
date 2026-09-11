const id = @import("../id.zig");
const HistoryEntryIterator = @import("HistoryEntryIterator.zig");
const HistoryResultsView = @This();

request_id: id.RequestId,
entry_count: u16,
encoded_entries: []const u8,
snapshot_id: u64 = 0,
has_more: bool = false,

pub fn entries(results: HistoryResultsView) HistoryEntryIterator {
    return .{
        .decoder = .init(results.encoded_entries),
        .remaining = results.entry_count,
    };
}
