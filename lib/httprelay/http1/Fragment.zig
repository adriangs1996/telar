/// One successfully forwarded body fragment.
///
/// `payload` excludes HTTP chunk framing. `forwarded_bytes` includes bytes
/// that count as body activity, including the CRLF after chunk data.
const Fragment = @This();

payload: []const u8,
forwarded_bytes: usize,
