const Request = @This();

event_id: u64,
bytes: []u8,
pane: @import("telar-core").schema.PaneId,
pane_generation: u64,
