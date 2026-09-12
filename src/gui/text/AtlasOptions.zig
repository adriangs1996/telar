//! How a glyph atlas is opened: the face bytes and the first size to
//! rasterize at. Runs may ask for other sizes later.

font: []const u8,
pixel_height: u16,
