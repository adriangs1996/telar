const PaneIdType = @import("telar-core").PaneId;
const Request = @This();

event_id: u64,
bytes: []u8,
pane: PaneIdType,
pane_generation: u64,
