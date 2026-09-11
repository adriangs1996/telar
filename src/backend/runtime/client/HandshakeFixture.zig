const admission = @import("admission.zig");
const HandshakeCapture = @import("HandshakeCapture.zig");
const HandshakeFixture = @This();

state: admission.AdmissionState = .{},
capture: HandshakeCapture = .{},

pub fn coordinator(fixture: *HandshakeFixture, connection_id: u8) admission.TestHandshakeCoordinator {
    fixture.state.begin(.{ .id = connection_id });
    fixture.capture.state = &fixture.state;
    return admission.TestHandshakeCoordinator.init(&fixture.capture, &fixture.state);
}
