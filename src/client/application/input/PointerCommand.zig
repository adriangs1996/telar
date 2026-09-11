const PointerCommand = @This();
const Mouse = @import("../../input/root.zig").Mouse;
event: Mouse,
exterior_pixels: bool,
cell_width_px: u16,
cell_height_px: u16,
