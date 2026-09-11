const HistoryResults = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
entries: []const source_namespace.HistoryEntry,
snapshot_id: u64 = 0,
has_more: bool = false,
