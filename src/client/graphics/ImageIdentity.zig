const ImageIdentity = @This();
const source_namespace = @import("store.zig");
pane_id: source_namespace.schema.PaneId,
image_id: u32,
generation: u64,
