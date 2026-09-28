const core = @import("telar-core");
const CreatedTab = @This();

location: core.TabLocation,
position: u16,
label: []const u8,
root_pane_id: core.PaneId,
pane_generation: u64 = 0,
