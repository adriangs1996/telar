const KeyType = @import("Key.zig");
const HalfType = @import("Half.zig");
const Exchange = @import("Exchange.zig");
const Entry = @This();

key: KeyType,
request: ?*HalfType = null,
response: ?*HalfType = null,
expires_at_ms: i64,

pub fn exchange(entry: Entry) Exchange {
    return .{ .request = entry.request, .response = entry.response };
}
