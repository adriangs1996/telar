const id = @import("id.zig");
const ImageKeyType = @import("../ImageKey.zig");
const ImageChunk = @This();

pane_id: id.PaneId,
revision: u64,
key: ImageKeyType,
offset: u64,
bytes: []const u8,
