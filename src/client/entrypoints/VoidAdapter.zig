const Capture = @import("Capture.zig");
const VoidAdapter = @This();

pub fn apply(capture: *Capture, _: anytype) !void {
    capture.calls += 1;
}
