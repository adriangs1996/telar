const CellSize = @import("CellSize.zig");
const PixelProjection = @This();

cell: CellSize,
exact: ?PixelPoint = null,

const PixelPoint = struct {
    x: u32,
    y: u32,
};
