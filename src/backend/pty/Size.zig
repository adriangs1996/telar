const Size = @This();

cols: u16,
rows: u16,
cell_width_px: u16 = 0,
cell_height_px: u16 = 0,

/// Replaces unusable zero cell dimensions with the terminal defaults.
///
/// ```zig
/// const size = requested.valid();
/// ```
pub fn valid(size: Size) Size {
    return .{
        .cols = if (size.cols == 0) 80 else size.cols,
        .rows = if (size.rows == 0) 24 else size.rows,
        .cell_width_px = size.cell_width_px,
        .cell_height_px = size.cell_height_px,
    };
}
