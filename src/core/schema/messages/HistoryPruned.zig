/// How many entries a delete or prune removed.
const HistoryPruned = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
removed: u64,
