//! Where one chrome label goes: the clip rectangle, the baseline and the
//! line box in device pixels, so cell and pixel callers share one painter.
bounds: @import("../render/Rect.zig"),
baseline: f32,
line: @import("../text/LineBox.zig"),
