const id = @import("../id.zig");
const HistoryEntry = @import("../HistoryEntry.zig");
const HistoryResults = @This();

request_id: id.RequestId,
entries: []const HistoryEntry,
snapshot_id: u64 = 0,
has_more: bool = false,
