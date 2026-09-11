const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const CloseTab = @This();

request_id: id.RequestId,
location: TabLocationType,
