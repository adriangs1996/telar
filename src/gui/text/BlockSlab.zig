//! A solid slab of eighths anchored to one edge of the cell.
const Side = @import("block_shapes.zig").Side;

side: Side,
/// 1 through 8; eight eighths anchored to the bottom is the full block.
eighths: u4,
