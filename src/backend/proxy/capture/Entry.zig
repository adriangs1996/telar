const Entry = @This();
const buffer = @import("buffer_support.zig");
const Exchange = @import("Exchange.zig");
key: buffer.Key,
request: ?*buffer.Half = null,
response: ?*buffer.Half = null,
expires_at_ms: i64,

pub fn exchange(entry: Entry) Exchange {
    return .{ .request = entry.request, .response = entry.response };
}
