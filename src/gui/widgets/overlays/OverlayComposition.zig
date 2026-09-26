//! Borrowed layout inputs for one synchronous overlay composition.
const client = @import("telar-client");
const router_module = @import("../../input/router.zig");
const Canvas = @import("../Canvas.zig");
canvas: *Canvas,
projection: *const client.Projection,
router: ?*const router_module.Type = null,
scale: f32 = 1,
history_reveal: f32 = 1,
/// Whether the history panel shows that a replacement page is late.
history_loading: bool = false,
