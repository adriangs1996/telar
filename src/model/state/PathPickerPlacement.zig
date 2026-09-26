//! The cells a path picker covers and which way it opens.

const cellgrid = @import("cellgrid");
const PathPickerPlacement = @This();

area: cellgrid.Rect,
/// The picker opens above the cursor: rows grow upward and the field is
/// its bottom row.
flipped: bool,
