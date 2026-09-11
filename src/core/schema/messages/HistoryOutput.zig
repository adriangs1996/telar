const id_module = @import("../id.zig");
/// The bounded raw output tail stored for one history entry; empty when
/// capture was off or the command printed nothing.
const HistoryOutput = @This();

request_id: id_module.RequestId,
id: u64,
truncated: bool,
observed_bytes: u64,
content: []const u8,
