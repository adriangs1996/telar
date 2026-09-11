const relay = @import("relay.zig");
const HeadersType = @import("../Headers.zig");
const HeaderEmission = @This();

direction: relay.Direction,
stream_id: u32,
headers: *const HeadersType,
