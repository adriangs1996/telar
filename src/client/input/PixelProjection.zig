const PixelProjection = @This();
const CellSize = @import("CellSize.zig");
const PixelPoint = @import("PixelPoint.zig");
cell: CellSize,
exact: ?PixelPoint = null,
