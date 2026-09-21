const Line = @import("telar-core").ChangeReviewDiffLine;
const Rect = @import("../render/Rect.zig");

line: Line,
fragment: []const u8,
bounds: Rect,
code: Rect,
paint: bool,
columns: u16 = 1,
line_height: f32 = 0,
start_y: f32 = 0,
