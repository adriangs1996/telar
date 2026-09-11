const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TabMoved = @This();

request_id: id.RequestId,
location: TabLocationType,
position: u16,
