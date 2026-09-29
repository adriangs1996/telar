//! What a placement asks for, in the units the protocol gives them: the
//! source rectangle's size in image pixels, the requested cells (zero means
//! not given), the pixel offset inside the first cell, and the cell size in
//! device pixels.
const DisplayRequest = @This();

source_width: u32,
source_height: u32,
columns: u32 = 0,
rows: u32 = 0,
offset_x: u32 = 0,
offset_y: u32 = 0,
cell_width: u32,
cell_height: u32,
