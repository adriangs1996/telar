//! What one Unicode placeholder cell says about the image fragment it shows.
//! The foreground color carries the low 24 bits of the image id and the
//! underline color the placement id; diacritics carry the row, the column and
//! the high byte of the image id. Missing parts continue the cell to the left.

image_id_low: u24,
/// From the third diacritic; null when the cell does not give it.
image_id_high: ?u8 = null,
/// Zero when the underline color names no placement.
placement_id: u24 = 0,
row: ?u32 = null,
column: ?u32 = null,
