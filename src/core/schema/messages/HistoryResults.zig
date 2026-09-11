const id = @import("../id.zig");
const HistoryEntryType = @import("../HistoryEntry.zig");
const HistoryResults = @This();

request_id: id.RequestId,
entries: []const HistoryEntryType,
snapshot_id: u64 = 0,
has_more: bool = false,
