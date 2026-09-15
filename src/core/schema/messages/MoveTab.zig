const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const types = @import("../types.zig");
const MoveTab = @This();

request_id: id.RequestId,
location: TabLocationType,
direction: types.TabMoveDirection,
relative_to: ?id.TabId = null,
