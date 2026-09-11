const RectType = @import("telar-core").Rect;
const PointType = @import("telar-core").Point;
const IconType = @import("telar-client").Icon;
const StyleType = @import("telar-core").Style;
const IconDraw = @This();

area: RectType,
point: PointType,
icon: IconType,
style: StyleType,
/// Cells the graphical mark may span sideways. The fallback glyph still
/// takes the first cell only; the caller blanks the rest.
columns: u16 = 1,
