//! Line widths for the visible portion of a table cell, without heap storage.
const Alignment = @This();

pub const capacity = 256;
kind: @import("MessageTable.zig").Alignment = .left,
first_row: usize = 0,
widths: [capacity]f32 = @splat(0),

/// Example: `alignment.observe(line_index, advance);`
pub fn observe(alignment: *Alignment, row: usize, width: f32) void {
    if (row >= alignment.first_row and row - alignment.first_row < capacity) {
        const index = row - alignment.first_row;
        alignment.widths[index] = @max(alignment.widths[index], width);
    }
}

/// Lines beyond the visible-width quota retain left alignment.
/// Example: `const x = bounds.x + alignment.offset(line_index, bounds.width);`
pub fn offset(alignment: *const Alignment, row: usize, width: f32) f32 {
    if (row < alignment.first_row or row - alignment.first_row >= capacity) {
        return 0;
    }

    const room = @max(0, width - alignment.widths[row - alignment.first_row]);
    return switch (alignment.kind) {
        .left => 0,
        .center => room / 2,
        .right => room,
    };
}
