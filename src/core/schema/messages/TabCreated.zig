const pane_kind = @import("../pane_kind.zig");
const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const TabCreated = @This();

request_id: id.RequestId,
location: TabLocationType,
position: u16,
label: []const u8,
root_pane_id: id.PaneId,

kind: pane_kind.PaneKind = .terminal,
pane_generation: u64 = 0,
