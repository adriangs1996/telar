const Key = @import("Key.zig");
const Half = @import("Half.zig");
const Exchange = @import("Exchange.zig");
const Entry = @This();

key: Key,
request: ?*Half = null,
response: ?*Half = null,
expires_at_ms: i64,

pub fn exchange(entry: Entry) Exchange {
    return .{ .request = entry.request, .response = entry.response };
}
