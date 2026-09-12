const CaptureRequestType = @import("CaptureRequest.zig");
/// Host clipboard media capture. `supported` answers without I/O; `start`
/// schedules one bounded capture whose result returns through the adapter.
const CapturePort = @This();

context: *anyopaque,
supported: *const fn (*anyopaque) bool,
start: *const fn (*anyopaque, CaptureRequestType) anyerror!void,

/// Example: `if (client.capture_port.platformSupported()) ...`.
pub fn platformSupported(port: CapturePort) bool {
    return port.supported(port.context);
}

/// Example: `try client.capture_port.schedule(request);`.
pub fn schedule(port: CapturePort, request: CaptureRequestType) !void {
    return port.start(port.context, request);
}
