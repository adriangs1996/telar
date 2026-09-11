const PixelPoint = @import("PixelPoint.zig");
const ModalRenderKey = @import("ModalRenderKey.zig");
const CornerPixel = @This();

destination: PixelPoint,
local: PixelPoint,
right: bool,
bottom: bool,
key: ModalRenderKey,
