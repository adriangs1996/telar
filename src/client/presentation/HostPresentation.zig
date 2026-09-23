const core = @import("telar-core");
const GeometryType = @import("Geometry.zig");
/// The adapter's presentation as the client application drives and queries
/// it: input pacing, the frame cadence timers align to, and the
/// geometry a pointer gesture may trust while a presentation is in flight.
const HostPresentation = @This();

context: *anyopaque,
note_input_fn: *const fn (*anyopaque, u64) void,
frame_interval_ns_fn: *const fn (*anyopaque) u64,
in_flight_fn: *const fn (*anyopaque) bool,
delivered_geometry_fn: *const fn (*anyopaque) ?GeometryType,
note_pane_input_fn: ?*const fn (*anyopaque, core.PaneId, u64) void = null,

/// Lets pacing spend an input-grace frame. Example: `client.presentation.noteInput(now_ns);`.
pub fn noteInput(port: HostPresentation, now_ns: u64) void {
    port.note_input_fn(port.context, now_ns);
}

/// Marks admitted child input, after routing and outbox admission succeed.
/// Example: `client.presentation.notePaneInput(delivery.pane_id, now_ns);`
pub fn notePaneInput(port: HostPresentation, pane_id: core.PaneId, now_ns: u64) void {
    if (port.note_pane_input_fn) |notify| {
        notify(port.context, pane_id, now_ns);
    }
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
