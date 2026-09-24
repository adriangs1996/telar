//! The visible palette rows of one prepared frame, addressed by result index.
//! This is the overlay's own bounded hit map; the chrome `HitMap` is not
//! involved, so its capacity does not change.
const cellgrid = @import("cellgrid");
const data = @import("model");
const PaletteHits = @This();

pub const capacity = 16;

rows: [capacity]cellgrid.Rect = undefined,
/// Result index of `rows[0]`; rows are consecutive after it.
first: u16 = 0,
count: u8 = 0,

/// Records the next visible row. Rows beyond the capacity are not painted,
/// so they are never recorded. Example: `hits.add(row);`.
pub fn add(self: *PaletteHits, area: cellgrid.Rect) void {
    if (self.count == capacity or area.isEmpty()) {
        return;
    }

    self.rows[self.count] = area;
    self.count += 1;
}

/// The result index under the pointer, if a row is there.
/// Example: `if (hits.at(mouse)) |index| choose(index);`.
pub fn at(self: *const PaletteHits, mouse: data.Mouse) ?u16 {
    for (self.rows[0..self.count], 0..) |row, offset| {
        if (row.contains(mouse.x, mouse.y)) {
            return self.first + @as(u16, @intCast(offset));
        }
    }

    return null;
}
