const PixelAllocation = @This();
const SharedPixels = @import("SharedPixels.zig");
pixels: []u8,
shared: ?SharedPixels = null,
