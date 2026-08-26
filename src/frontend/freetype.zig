//! Narrow C surface used by the client-side text rasterizer.

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftbitmap.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
