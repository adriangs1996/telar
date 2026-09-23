const id = @import("id.zig");
const ImageKey = @import("../ImageKey.zig");
const ImageChunk = @This();

pane_id: id.PaneId,
revision: u64,
key: ImageKey,
offset: u64,
bytes: []const u8,
