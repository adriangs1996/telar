/// One borrowed HTTP/2 request-body fragment associated with its stream.
const Fragment = @This();

stream_id: u32,
bytes: []const u8,
