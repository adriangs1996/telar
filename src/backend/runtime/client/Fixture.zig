const admission = @import("admission.zig");
const AdmissionCapture = @import("AdmissionCapture.zig");
const Fixture = @This();

state: admission.AdmissionState = .{},
capture: AdmissionCapture = .{},

pub fn coordinator(fixture: *Fixture) admission.TestCoordinator {
    fixture.capture.state = &fixture.state;
    return admission.TestCoordinator.init(&fixture.capture, &fixture.state);
}
