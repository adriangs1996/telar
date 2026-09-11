const frame_support = @import("frame_support.zig");
const Mouse = @This();

tracking: frame_support.MouseTracking = .none,
sgr: bool = false,
pixels: bool = false,
