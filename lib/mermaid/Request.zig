//! One diagram source to render, borrowed for the duration of the render.
const Theme = @import("Theme.zig");
const Request = @This();

source: []const u8,
theme: Theme,
scale: f32,
