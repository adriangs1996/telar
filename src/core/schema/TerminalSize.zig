const frame = @import("frame_support.zig");
const TerminalSize = @This();

cols: u16,
rows: u16,
/// Pixel size of one cell. Zero means the client has not learned it.
cell_width_px: u16 = 0,
cell_height_px: u16 = 0,

pub fn validate(self: TerminalSize) !void {
    if (self.cols == 0 or self.rows == 0) {
        return error.InvalidTerminalSize;
    }
    const cells = @as(u32, self.cols) * @as(u32, self.rows);
    if (cells > frame.max_cell_count) {
        return error.ScreenTooLarge;
    }
}
