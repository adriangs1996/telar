//! The visible palette rows of one prepared frame, addressed by result index.
//! This is the overlay's own bounded hit map; the chrome `HitMap` is not
//! involved, so its capacity does not change.
const core = @import("telar-core");
const client = @import("telar-client");
const PaletteHits = @This();

pub const capacity = 16;

rows: [capacity]core.Rect = undefined,
/// Result index of `rows[0]`; rows are consecutive after it.
first: u16 = 0,
count: u8 = 0,

/// Records the next visible row. Rows beyond the capacity are not painted,
/// so they are never recorded. Example: `hits.add(row);`.
pub fn add(hits: *PaletteHits, area: core.Rect) void {
    if (hits.count == capacity or area.isEmpty()) {
        return;
    }

    hits.rows[hits.count] = area;
    hits.count += 1;
}

/// The result index under the pointer, if a row is there.
/// Example: `if (hits.at(mouse)) |index| choose(index);`.
pub fn at(hits: *const PaletteHits, mouse: client.Mouse) ?u16 {
    for (hits.rows[0..hits.count], 0..) |row, offset| {
        if (row.contains(mouse.x, mouse.y)) {
            return hits.first + @as(u16, @intCast(offset));
        }
    }

    return null;
}
