const VoidAdapter = @This();
const Capture = @import("Capture.zig");
pub fn apply(capture: *Capture, _: anytype) !void {
    capture.calls += 1;
}
