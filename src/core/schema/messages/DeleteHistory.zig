/// Deletes one exact history entry.
const DeleteHistory = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
id: u64,
