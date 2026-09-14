//! Borrowed layout inputs for one synchronous overlay composition.
canvas: *@import("../Canvas.zig"),
projection: *const @import("telar-client").Projection,
router: ?*const @import("../../input/router.zig").Type = null,
scale: f32 = 1,
