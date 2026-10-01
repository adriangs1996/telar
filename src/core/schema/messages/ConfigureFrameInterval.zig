/// The interval at which a client presents frames, from its display's refresh
/// rate or a lower cap its user set. The runtime paces each attachment's cell
/// frames to it, so a 120 Hz window receives pane output at 120 Hz. Sent in
/// the bootstrap and again whenever the interval changes.
const types = @import("../types.zig");
const ConfigureFrameInterval = @This();

interval_ns: u64,

/// Refuses an interval outside the wire bounds, so no client asks the
/// runtime for frames faster than 240 Hz or slower than 30 Hz.
///
/// ```zig
/// try (ConfigureFrameInterval{ .interval_ns = interval }).validateWire();
/// ```
pub fn validateWire(self: ConfigureFrameInterval) !void {
    if (self.interval_ns < types.min_frame_interval_ns or self.interval_ns > types.max_frame_interval_ns) {
        return error.InvalidFrameInterval;
    }
}
