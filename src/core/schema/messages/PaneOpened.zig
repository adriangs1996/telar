const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const PaneOpened = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
location: TabLocation,
created: bool,

pane_generation: u64 = 0,
