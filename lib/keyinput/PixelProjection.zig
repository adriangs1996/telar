const PixelProjection = @This();

cell: CellSize,
exact: ?PixelPoint = null,

const PixelPoint = struct {
    x: u32,
    y: u32,
};

const CellSize = struct {
    width: u16,
    height: u16,
};
