const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const RequestTabSnapshot = @This();

request_id: id.RequestId,
location: TabLocation,
