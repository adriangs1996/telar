const TerminalSize = @This();
const frame = @import("frame_support.zig");
cols: u16,
rows: u16,
/// Pixel size of one cell. Zero means the client has not learned it.
cell_width_px: u16 = 0,
cell_height_px: u16 = 0,

pub fn validate(size: TerminalSize) !void {
    if (size.cols == 0 or size.rows == 0) {
        return error.InvalidTerminalSize;
    }
    const cells = @as(u32, size.cols) * @as(u32, size.rows);
    if (cells > frame.max_cell_count) {
        return error.ScreenTooLarge;
    }
}
