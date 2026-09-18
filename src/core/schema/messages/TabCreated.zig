const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TabCreated = @This();

request_id: id.RequestId,
location: TabLocationType,
position: u16,
label: []const u8,
root_pane_id: id.PaneId,

kind: @import("../pane_kind.zig").PaneKind = .terminal,
pane_generation: u64 = 0,
