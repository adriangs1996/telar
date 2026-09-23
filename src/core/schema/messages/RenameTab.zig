const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const RenameTab = @This();

request_id: id.RequestId,
location: TabLocation,
label: []const u8,
