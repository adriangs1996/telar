const Surface = @import("Surface.zig");
const freetype = @import("freetype");
const RasterizerPoint = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
const BitmapBlend = @This();

surface: Surface,
bitmap: freetype.c.FT_Bitmap,
destination: RasterizerPoint,
color: Color,
