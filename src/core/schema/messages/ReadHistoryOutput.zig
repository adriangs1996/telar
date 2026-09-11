/// Reads the captured output of one exact history entry.
const ReadHistoryOutput = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
id: u64,
