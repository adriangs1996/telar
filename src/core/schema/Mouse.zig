const Mouse = @This();
const source_namespace = @import("frame_support.zig");
tracking: source_namespace.MouseTracking = .none,
sgr: bool = false,
pixels: bool = false,
