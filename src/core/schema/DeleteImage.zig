const id = @import("id.zig");
const ImageKeyType = @import("../ImageKey.zig");
const DeleteImage = @This();

pane_id: id.PaneId,
revision: u64,
key: ImageKeyType,
