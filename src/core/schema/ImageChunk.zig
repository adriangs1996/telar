const ImageChunk = @This();
const source_namespace = @import("graphics.zig");
const shared = @import("../graphics.zig");
pane_id: source_namespace.PaneId,
revision: u64,
key: shared.ImageKey,
offset: u64,
bytes: []const u8,
