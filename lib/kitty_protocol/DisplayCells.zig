//! The cells a placement covers from its anchor cell, which is how far a
//! terminal moves the cursor after placing it.
const DisplayCells = @This();

columns: u32,
rows: u32,
