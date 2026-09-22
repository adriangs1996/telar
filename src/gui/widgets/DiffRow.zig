const core = @import("telar-core");
const Rect = @import("../render/Rect.zig");

line: core.ChangeReviewDiffLine,
fragment: []const u8,
bounds: Rect,
code: Rect,
paint: bool,
columns: u16 = 1,
line_height: f32 = 0,
start_y: f32 = 0,
