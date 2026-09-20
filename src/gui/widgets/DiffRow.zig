const Line = @import("telar-core").ChangeReviewDiffLine;
const Rect = @import("../render/Rect.zig");

line: Line,
fragment: []const u8,
bounds: Rect,
code: Rect,
paint: bool,
