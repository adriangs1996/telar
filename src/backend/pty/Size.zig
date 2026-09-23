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
pub fn valid(self: Size) Size {
    return .{
        .cols = if (self.cols == 0) 80 else self.cols,
        .rows = if (self.rows == 0) 24 else self.rows,
        .cell_width_px = self.cell_width_px,
        .cell_height_px = self.cell_height_px,
    };
}
