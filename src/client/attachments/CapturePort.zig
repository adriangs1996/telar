/// Host clipboard media capture. `supported` answers without I/O; `start`
/// schedules one bounded capture whose result returns through the adapter.
const data = @import("model");
const CapturePort = @This();

context: *anyopaque,
supported: *const fn (*anyopaque) bool,
start: *const fn (*anyopaque, data.CaptureRequest) anyerror!void,

/// Example: `if (client.capture_port.platformSupported()) ...`.
pub fn platformSupported(port: CapturePort) bool {
    return port.supported(port.context);
}

/// Example: `try client.capture_port.schedule(request);`.
pub fn schedule(port: CapturePort, request: data.CaptureRequest) !void {
    return port.start(port.context, request);
}
