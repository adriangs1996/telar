const HistoryResultsView = @This();
const source_namespace = @import("history.zig");
const HistoryEntryIterator = @import("HistoryEntryIterator.zig");
request_id: source_namespace.RequestId,
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
