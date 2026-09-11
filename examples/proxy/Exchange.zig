const event = @import("event.zig");
/// One intercepted request/response pair, already readable.
const Exchange = @This();

id: u64,
host: event.Host,
port: u16,
request_bytes: u64,
response_bytes: u64,
duration_ms: i64,
/// Redacted head plus captured bodies, ready to store. Allocated by the
/// producing actor and **owned by the receiver**, which must free it.
detail: ?[]const u8 = null,
truncated: bool = false,
