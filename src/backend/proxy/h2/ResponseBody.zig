const ResponseBody = @This();

stream_id: u32,
status_code: u16,
sse_body: bool,
bytes: []const u8,
