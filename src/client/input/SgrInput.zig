const data = @import("model");
const core = @import("telar-core");
const PixelProjection = @import("PixelProjection.zig");
const SgrInput = @This();

event: data.Mouse,
pane_position: core.Point,
pixels: ?PixelProjection = null,
