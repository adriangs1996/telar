//! Which machine the window presents and the cell size, in device pixels,
//! its placements resolve against.
const ImageView = @This();

machine: u8,
cell_width: u32,
cell_height: u32,
