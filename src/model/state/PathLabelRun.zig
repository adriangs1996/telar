//! One styled stretch of a path picker row.

const PathLabel = @import("PathLabel.zig");
const PathLabelRun = @This();

text: []const u8,
tone: PathLabel.Tone,
