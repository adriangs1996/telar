const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const types = @import("../types.zig");

request_id: id.RequestId,
location: TabLocation,
direction: types.TabMoveDirection,
relative_to: ?id.TabId = null,
