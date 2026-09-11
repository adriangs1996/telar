const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TabRenamed = @This();

request_id: id.RequestId,
location: TabLocationType,
label: []const u8,
