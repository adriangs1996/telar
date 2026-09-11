const MarkerPosition = @This();
const source_namespace = @import("markers.zig");
number: u16,
/// The `[` cell.
start: source_namespace.ui.Point,
/// One past the `]` cell, on the row holding it.
end: source_namespace.ui.Point,

pub fn contiguous(marker: MarkerPosition) bool {
    return marker.start.y == marker.end.y;
}
