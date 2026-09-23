//! Line widths for the visible portion of a table cell, without heap storage.
const MessageTable = @import("MessageTable.zig");
const Alignment = @This();

pub const capacity = 256;
kind: MessageTable.Alignment = .left,
first_row: usize = 0,
widths: [capacity]f32 = @splat(0),

/// Example: `alignment.observe(line_index, advance);`
pub fn observe(self: *Alignment, row: usize, width: f32) void {
    if (row >= self.first_row and row - self.first_row < capacity) {
        const index = row - self.first_row;
        self.widths[index] = @max(self.widths[index], width);
    }
}

/// Lines beyond the visible-width quota retain left alignment.
/// Example: `const x = bounds.x + alignment.offset(line_index, bounds.width);`
pub fn offset(self: *const Alignment, row: usize, width: f32) f32 {
    if (row < self.first_row or row - self.first_row >= capacity) {
        return 0;
    }

    const room = @max(0, width - self.widths[row - self.first_row]);
    return switch (self.kind) {
        .left => 0,
        .center => room / 2,
        .right => room,
    };
}
