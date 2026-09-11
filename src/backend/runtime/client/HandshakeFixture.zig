const HandshakeFixture = @This();
const source_namespace = @import("admission.zig");
const HandshakeCapture = @import("HandshakeCapture.zig");
state: source_namespace.AdmissionState = .{},
capture: HandshakeCapture = .{},

pub fn coordinator(fixture: *HandshakeFixture, connection_id: u8) source_namespace.TestHandshakeCoordinator {
    fixture.state.begin(.{ .id = connection_id });
    fixture.capture.state = &fixture.state;
    return source_namespace.TestHandshakeCoordinator.init(&fixture.capture, &fixture.state);
}
