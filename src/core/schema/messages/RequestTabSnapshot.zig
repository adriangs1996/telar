const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const RequestTabSnapshot = @This();

request_id: id.RequestId,
location: TabLocationType,
