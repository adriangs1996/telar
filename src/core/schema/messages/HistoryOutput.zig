/// The bounded raw output tail stored for one history entry; empty when
/// capture was off or the command printed nothing.
const HistoryOutput = @This();
const source_namespace = @import("history.zig");
request_id: source_namespace.RequestId,
id: u64,
truncated: bool,
observed_bytes: u64,
content: []const u8,
