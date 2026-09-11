const id = @import("../id.zig");
/// How many entries a delete or prune removed.
const HistoryPruned = @This();

request_id: id.RequestId,
removed: u64,
