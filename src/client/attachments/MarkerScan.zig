/// Visits every `[Image #N]` marker on the screen in row-major order of its
/// head cell, including markers wrapped onto a second row.
const MarkerScan = @This();
const source_namespace = @import("markers.zig");
const MarkerPosition = @import("MarkerPosition.zig");
buffer: *const source_namespace.ui.Buffer,
x: u16 = 0,
y: u16 = 0,

pub fn next(scan: *MarkerScan) ?MarkerPosition {
    const buffer = scan.buffer;
    while (scan.y < buffer.h and scan.x + source_namespace.marker_head_width <= buffer.w) {
        const at: source_namespace.ui.Point = .{ .x = scan.x, .y = scan.y };
        if (scan.x + source_namespace.marker_head_width < buffer.w) {
            scan.x += 1;
        } else {
            scan.x = 0;
            scan.y += 1;
        }

        if (source_namespace.parseMarker(buffer, at)) |marker| {
            return marker;
        }
    }

    return null;
}
