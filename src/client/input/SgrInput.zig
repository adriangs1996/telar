const Mouse = @import("Mouse.zig");
const PointType = @import("telar-core").Point;
const PixelProjection = @import("PixelProjection.zig");
const SgrInput = @This();

event: Mouse,
pane_position: PointType,
pixels: ?PixelProjection = null,
