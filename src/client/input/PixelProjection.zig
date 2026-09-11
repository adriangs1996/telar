const CellSize = @import("CellSize.zig");
const PixelPoint = @import("PixelPoint.zig");
const PixelProjection = @This();

cell: CellSize,
exact: ?PixelPoint = null,
