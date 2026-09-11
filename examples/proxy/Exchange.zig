/// One intercepted request/response pair, already readable.
const Exchange = @This();
const source_namespace = @import("event.zig");
id: u64,
host: source_namespace.Host,
port: u16,
request_bytes: u64,
response_bytes: u64,
duration_ms: i64,
/// Redacted head plus captured bodies, ready to store. Allocated by the
/// producing actor and **owned by the receiver**, which must free it.
detail: ?[]const u8 = null,
truncated: bool = false,
