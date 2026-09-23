const core = @import("telar-core");
const MarkerPosition = @import("MarkerPosition.zig");
const markers = @import("markers.zig");
/// Visits every `[Image #N]` marker on the screen in row-major order of its
/// head cell, including markers wrapped onto a second row.
const MarkerScan = @This();

buffer: *const core.Buffer,
x: u16 = 0,
y: u16 = 0,

pub fn next(self: *MarkerScan) ?MarkerPosition {
    const buffer = self.buffer;
    while (self.y < buffer.h and self.x + markers.marker_head_width <= buffer.w) {
        const at: core.Point = .{ .x = self.x, .y = self.y };
        if (self.x + markers.marker_head_width < buffer.w) {
            self.x += 1;
        } else {
            self.x = 0;
            self.y += 1;
        }

        if (markers.parseMarker(buffer, at)) |marker| {
            return marker;
        }
    }

    return null;
}
