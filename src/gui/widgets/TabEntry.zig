//! One tab of the strip with its position in the collection and its slot.
const client = @import("telar-client");
tab: *const client.Tab,
index: usize,
bounds: @import("../render/Rect.zig"),
