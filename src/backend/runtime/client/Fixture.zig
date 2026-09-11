const Fixture = @This();
const source_namespace = @import("admission.zig");
const Capture = @import("AdmissionCapture.zig");
state: source_namespace.AdmissionState = .{},
capture: Capture = .{},

pub fn coordinator(fixture: *Fixture) source_namespace.TestCoordinator {
    fixture.capture.state = &fixture.state;
    return source_namespace.TestCoordinator.init(&fixture.capture, &fixture.state);
}
