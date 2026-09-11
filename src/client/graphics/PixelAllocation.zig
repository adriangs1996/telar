const SharedPixels = @import("SharedPixels.zig");
const PixelAllocation = @This();

pixels: []u8,
shared: ?SharedPixels = null,
