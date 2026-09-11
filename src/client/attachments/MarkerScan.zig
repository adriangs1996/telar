const BufferType = @import("telar-core").Buffer;
const MarkerPosition = @import("MarkerPosition.zig");
const markers = @import("markers.zig");
const PointType = @import("telar-core").Point;
/// Visits every `[Image #N]` marker on the screen in row-major order of its
/// head cell, including markers wrapped onto a second row.
const MarkerScan = @This();

buffer: *const BufferType,
x: u16 = 0,
y: u16 = 0,

pub fn next(scan: *MarkerScan) ?MarkerPosition {
    const buffer = scan.buffer;
    while (scan.y < buffer.h and scan.x + markers.marker_head_width <= buffer.w) {
        const at: PointType = .{ .x = scan.x, .y = scan.y };
        if (scan.x + markers.marker_head_width < buffer.w) {
            scan.x += 1;
        } else {
            scan.x = 0;
            scan.y += 1;
        }

        if (markers.parseMarker(buffer, at)) |marker| {
            return marker;
        }
    }

    return null;
}
