const id = @import("../id.zig");
const TabLocation = @import("../TabLocation.zig");
const TabCreated = @This();

request_id: id.RequestId,
location: TabLocation,
position: u16,
label: []const u8,
root_pane_id: id.PaneId,

pane_generation: u64 = 0,
