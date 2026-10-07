const id = @import("id.zig");
const ImageKey = @import("../ImageKey.zig");

pane_id: id.PaneId,
revision: u64,
key: ImageKey,
virtual_id: u64,
placement_id: u32,
