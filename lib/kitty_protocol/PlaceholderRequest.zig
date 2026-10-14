//! What drawing one placeholder run needs: the image size in pixels, the
//! virtual placement's grid in cells (zero means not given), the run and the
//! cell size in device pixels.
const PlaceholderRun = @import("PlaceholderRun.zig");

image_width: u32,
image_height: u32,
grid_columns: u32 = 0,
grid_rows: u32 = 0,
run: PlaceholderRun,
cell_width: u32,
cell_height: u32,
