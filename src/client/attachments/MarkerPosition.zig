const cellgrid = @import("cellgrid");
const MarkerPosition = @This();

number: u16,
/// The `[` cell.
start: cellgrid.Point,
/// One past the `]` cell, on the row holding it.
end: cellgrid.Point,

pub fn contiguous(self: MarkerPosition) bool {
    return self.start.y == self.end.y;
}
