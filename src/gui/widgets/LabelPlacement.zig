//! Where one chrome label goes: the clip rectangle, the baseline and the
//! line box in device pixels, so cell and pixel callers share one painter.
const gfx = @import("gfx");
const Rect = gfx.Rect;
const LineBox = @import("../text/LineBox.zig");

bounds: Rect,
baseline: f32,
line: LineBox,
