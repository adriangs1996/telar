const id_module = @import("../id.zig");
/// Reads the captured output of one exact history entry.
const ReadHistoryOutput = @This();

request_id: id_module.RequestId,
id: u64,
