const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const IconDraw = @This();

area: core.Rect,
point: core.Point,
icon: data.icons.Icon,
style: core.Style,
/// Cells the graphical mark may span sideways. The fallback glyph still
/// takes the first cell only; the caller blanks the rest.
columns: u16 = 1,
