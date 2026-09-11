const IconDraw = @This();
const ui = @import("../ui/root.zig");
const core = @import("telar-core");
const source_namespace = @import("context_support.zig");
area: ui.Rect,
point: core.ui.Point,
icon: source_namespace.icons.Icon,
style: ui.Style,
/// Cells the graphical mark may span sideways. The fallback glyph still
/// takes the first cell only; the caller blanks the rest.
columns: u16 = 1,
