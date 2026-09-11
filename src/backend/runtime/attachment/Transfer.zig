const ImageType = @import("telar-core").Image;
const ShmNameType = @import("telar-core").ShmName;
const max_placements_per_pane_module = @import("telar-core").max_placements_per_pane;
const PlacementType = @import("telar-core").Placement;
const Transfer = @This();

metadata: ImageType,
pixels: []u8,
shared_name: ?ShmNameType = null,
reserved_len: usize = 0,
placements: [max_placements_per_pane_module]PlacementType = undefined,
placement_count: usize = 0,
placement_index: usize = 0,
offset: usize = 0,
metadata_sent: bool = false,
