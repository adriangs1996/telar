const CornerPixel = @This();
const PixelPoint = @import("PixelPoint.zig");
const RenderKey = @import("ModalRenderKey.zig");
destination: PixelPoint,
local: PixelPoint,
right: bool,
bottom: bool,
key: RenderKey,
