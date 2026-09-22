const core = @import("telar-core");
const Transfer = @This();

metadata: core.Image,
pixels: []u8,
shared_name: ?core.ShmName = null,
reserved_len: usize = 0,
placements: [core.max_placements_per_pane]core.Placement = undefined,
placement_count: usize = 0,
placement_index: usize = 0,
offset: usize = 0,
metadata_sent: bool = false,
