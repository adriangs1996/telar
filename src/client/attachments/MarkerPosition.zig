const core = @import("telar-core");
const MarkerPosition = @This();

number: u16,
/// The `[` cell.
start: core.Point,
/// One past the `]` cell, on the row holding it.
end: core.Point,

pub fn contiguous(self: MarkerPosition) bool {
    return self.start.y == self.end.y;
}
