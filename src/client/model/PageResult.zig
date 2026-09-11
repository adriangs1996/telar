const HistoryEntryType = @import("telar-core").HistoryEntry;
const PageResult = @This();

request_id: u64,
entries: []const HistoryEntryType,
snapshot_id: u64,
has_more: bool,
now_ms: i64,
