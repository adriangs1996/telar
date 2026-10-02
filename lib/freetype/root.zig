//! Narrow C surface of the FreeType and HarfBuzz sources `build/freetype.zig`
//! compiles, used by the text rasterizer and the native client's fonts.

pub const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftbitmap.h");
    @cInclude("freetype/tttables.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("hb-ot.h");
});
