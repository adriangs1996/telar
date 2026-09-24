const keyinput = @import("keyinput");
const frame_support = @import("frame_support.zig");
const Mouse = @This();

tracking: keyinput.MouseTracking = .none,
sgr: bool = false,
pixels: bool = false,
