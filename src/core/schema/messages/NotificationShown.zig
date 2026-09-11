const id = @import("../id.zig");
const NotificationShown = @This();

request_id: id.RequestId,
delivered_clients: u8,
