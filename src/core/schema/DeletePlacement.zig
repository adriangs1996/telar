const id = @import("id.zig");
const ImageKey = @import("../ImageKey.zig");
const DeletePlacement = @This();

pane_id: id.PaneId,
revision: u64,
key: ImageKey,
virtual_id: u64,
placement_id: u32,
