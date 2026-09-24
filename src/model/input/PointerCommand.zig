const keyinput = @import("keyinput");
const Mouse = keyinput.Mouse;
const PointerCommand = @This();

event: Mouse,
exterior_pixels: bool,
cell_width_px: u16,
cell_height_px: u16,
