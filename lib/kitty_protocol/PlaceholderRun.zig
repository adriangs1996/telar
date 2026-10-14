//! Consecutive placeholder cells of one row that show adjacent fragments of
//! one image row: where the run starts on the screen, which fragment it
//! starts at and how many cells it spans.
const PlaceholderCell = @import("PlaceholderCell.zig");
const PlaceholderRun = @This();

/// The screen column of the run's first cell.
x: u32,
image_id: u32,
/// Zero when the cells name no placement: the image's first virtual
/// placement sizes them.
placement_id: u32,
/// The image grid row and column of the first cell.
row: u32,
column: u32,
width: u32 = 1,
image_id_high: ?u8,
image_id_low: u24,

/// Starts a run at screen column `x`; missing diacritics mean row and
/// column zero, as kitty and Ghostty read them.
/// Example: `var run = PlaceholderRun.start(cell, x);`
pub fn start(cell: PlaceholderCell, x: u32) PlaceholderRun {
    const high: u32 = cell.image_id_high orelse 0;
    return .{
        .x = x,
        .image_id = @as(u32, cell.image_id_low) | (high << 24),
        .placement_id = cell.placement_id,
        .row = cell.row orelse 0,
        .column = cell.column orelse 0,
        .image_id_high = cell.image_id_high,
        .image_id_low = cell.image_id_low,
    };
}

/// Extends the run by the next cell when it continues it: same image and
/// placement, and any row, column or high byte it gives matches what the
/// run implies. Kitty's rule; Ghostty follows it.
/// Example: `if (!run.extend(cell)) { emit(run); run = .start(cell, x); }`
pub fn extend(self: *PlaceholderRun, cell: PlaceholderCell) bool {
    if (cell.image_id_low != self.image_id_low or cell.placement_id != self.placement_id) {
        return false;
    }

    if (cell.row) |row| {
        if (row != self.row) {
            return false;
        }
    }

    if (cell.column) |column| {
        if (column != self.column + self.width) {
            return false;
        }
    }

    if (cell.image_id_high) |high| {
        if (self.image_id_high != high) {
            return false;
        }
    }

    self.width += 1;
    return true;
}
