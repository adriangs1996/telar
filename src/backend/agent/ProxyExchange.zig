const types = @import("types.zig");
/// Identifies one intercepted model exchange within the proxy observation
/// stream.
///
/// `stream_id` is zero for HTTP/1.1 and upgraded connections. HTTP/2 normally
/// uses its peer stream identifier; a `request_failed` observation may use zero
/// to settle every active stream on the named connection.
const ProxyExchange = @This();

protocol: types.ProxyProtocol,
connection_id: u64,
stream_id: u32,
