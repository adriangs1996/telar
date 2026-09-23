const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const TabMoved = @This();

request_id: id.RequestId,
location: TabLocation,
position: u16,
