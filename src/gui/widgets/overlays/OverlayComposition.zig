//! Borrowed layout inputs for one synchronous overlay composition.
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
canvas: *Canvas,
projection: *const client.Projection,
router: ?*const client.key_router.Type = null,
scale: f32 = 1,
history_reveal: f32 = 1,
/// Whether the history panel shows that a replacement page is late.
history_loading: bool = false,
