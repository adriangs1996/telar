//! A file path and the line and column a link points at. Zero means the
//! link did not say.

path: []const u8,
line: u32 = 0,
column: u32 = 0,
