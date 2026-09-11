const PointType = @import("telar-core").Point;
const MarkerPosition = @This();

number: u16,
/// The `[` cell.
start: PointType,
/// One past the `]` cell, on the row holding it.
end: PointType,

pub fn contiguous(marker: MarkerPosition) bool {
    return marker.start.y == marker.end.y;
}
