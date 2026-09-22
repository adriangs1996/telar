const pane_kind = @import("../pane_kind.zig");
const id = @import("../id.zig");
const TabLocationType = @import("../TabLocation.zig");
const PaneOpened = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
location: TabLocationType,
created: bool,

kind: pane_kind.PaneKind = .terminal,
pane_generation: u64 = 0,
