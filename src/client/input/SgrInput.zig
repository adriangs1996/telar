const SgrInput = @This();
const Mouse = @import("key_support.zig").Mouse;
const source_namespace = @import("mouse_protocol.zig");
const PixelProjection = @import("PixelProjection.zig");
event: Mouse,
pane_position: source_namespace.ui.Point,
pixels: ?PixelProjection = null,
