//! One tab of the strip with its position in the collection and its slot.
const data = @import("model");
const client = @import("telar-client");
tab: *const data.Tab,
index: usize,
bounds: @import("../render/Rect.zig"),
