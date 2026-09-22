const core = @import("telar-core");
const Request = @This();

event_id: u64,
bytes: []u8,
pane: core.PaneId,
pane_generation: u64,
