const GeometryType = @import("Geometry.zig");
/// The adapter's presentation as the client application drives and queries
/// it: host size, input pacing, the frame cadence timers align to, and the
/// geometry a pointer gesture may trust while a presentation is in flight.
const HostPresentation = @This();

context: *anyopaque,
resize_fn: *const fn (*anyopaque, u16, u16) anyerror!void,
note_input_fn: *const fn (*anyopaque, u64) void,
frame_interval_ns_fn: *const fn (*anyopaque) u64,
in_flight_fn: *const fn (*anyopaque) bool,
delivered_geometry_fn: *const fn (*anyopaque) ?GeometryType,

/// Example: `try client.presentation.resize(size.cols, size.rows);`.
pub fn resize(port: HostPresentation, cols: u16, rows: u16) !void {
    return port.resize_fn(port.context, cols, rows);
}

/// Lets pacing spend an input-grace frame. Example: `client.presentation.noteInput(now_ns);`.
pub fn noteInput(port: HostPresentation, now_ns: u64) void {
    port.note_input_fn(port.context, now_ns);
}

/// The cadence timers align their deadlines to.
pub fn frameIntervalNs(port: HostPresentation) u64 {
    return port.frame_interval_ns_fn(port.context);
}

/// Whether one prepared presentation awaits delivery.
pub fn inFlight(port: HostPresentation) bool {
    return port.in_flight_fn(port.context);
}

/// The geometry of the last delivered presentation, if any was delivered.
pub fn deliveredGeometry(port: HostPresentation) ?GeometryType {
    return port.delivered_geometry_fn(port.context);
}
