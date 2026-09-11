const BitmapBlend = @This();
const Surface = @import("Surface.zig");
const ft = @import("freetype").c;
const Point = @import("RasterizerPoint.zig");
const Color = @import("Color.zig");
surface: Surface,
bitmap: ft.FT_Bitmap,
destination: Point,
color: Color,
