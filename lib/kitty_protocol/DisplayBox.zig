//! Where a placement's pixels land relative to its anchor cell's top-left
//! corner, in device pixels.
const DisplayBox = @This();

offset_x: u32,
offset_y: u32,
width: u32,
height: u32,
