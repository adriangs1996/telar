//! The part of an image one placeholder run shows and where it lands: the
//! source rectangle in image pixels and the box relative to the run's first
//! cell in device pixels.
const DisplayBox = @import("DisplayBox.zig");

source_x: u32,
source_y: u32,
source_width: u32,
source_height: u32,
box: DisplayBox,
