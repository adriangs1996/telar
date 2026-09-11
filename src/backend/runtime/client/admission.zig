//! Single-flight admission of accepted client sockets.

const GenericState = @import("GenericState.zig").Type;
const FakeConnection = @import("FakeConnection.zig");
const GenericAcceptPort = @import("GenericAcceptPort.zig").Type;
const AdmissionCapture = @import("AdmissionCapture.zig");
const GenericAcceptCoordinator = @import("GenericAcceptCoordinator.zig").Type;
const std = @import("std");
const Fixture = @import("Fixture.zig");
const GenericHandshakePort = @import("GenericHandshakePort.zig").Type;
const HandshakeCapture = @import("HandshakeCapture.zig");
const TestHandshakeTypes = @import("TestHandshakeTypes.zig");
const GenericHandshakeCoordinator = @import("GenericHandshakeCoordinator.zig").Type;
const HandshakeFixture = @import("HandshakeFixture.zig");

pub const AdmissionState = GenericState(FakeConnection);

pub const Step = enum {
    stopping,
    rearm_accept,
    capacity,
    shutdown_connection,
    deinit_connection,
    start_handshake,
};

const test_port: GenericAcceptPort(AdmissionCapture, FakeConnection) = .{
    .stopping = AdmissionCapture.stopping,
    .rearm_accept = AdmissionCapture.rearmAccept,
    .has_capacity = AdmissionCapture.hasCapacity,
    .shutdown_connection = AdmissionCapture.shutdownConnection,
    .deinit_connection = AdmissionCapture.deinitConnection,
    .start_handshake = AdmissionCapture.startHandshake,
};

pub const TestCoordinator = GenericAcceptCoordinator(AdmissionCapture, FakeConnection, test_port);

fn expectSteps(capture: *const AdmissionCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "an accept failure rearms the listener without touching admission state" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();

    try coordinator.handle(error.AcceptFailed);

    try expectSteps(&fixture.capture, &.{.rearm_accept});
    try std.testing.expect(!fixture.state.isPending());
}

test "rearm failure after an accept failure propagates" {
    var fixture: Fixture = .{};
    fixture.capture.rearm_failure = true;
    var coordinator = fixture.coordinator();

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(error.AcceptFailed));

    try expectSteps(&fixture.capture, &.{.rearm_accept});
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.deinitialized_count);
}

test "runtime shutdown closes an accepted socket without rearming" {
    var fixture: Fixture = .{};
    fixture.capture.runtime_stopping = true;
    var coordinator = fixture.coordinator();

    try coordinator.handle(.{ .id = 2 });

    try expectSteps(&fixture.capture, &.{ .stopping, .deinit_connection });
    try std.testing.expectEqualSlices(u8, &.{2}, fixture.capture.deinitialized_ids[0..fixture.capture.deinitialized_count]);
    try std.testing.expect(!fixture.state.isPending());
}

test "rearm failure closes the accepted socket before propagating" {
    var fixture: Fixture = .{};
    fixture.capture.rearm_failure = true;
    var coordinator = fixture.coordinator();

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{ .id = 3 }));

    try expectSteps(&fixture.capture, &.{ .stopping, .rearm_accept, .deinit_connection });
    try std.testing.expectEqualSlices(u8, &.{3}, fixture.capture.deinitialized_ids[0..fixture.capture.deinitialized_count]);
    try std.testing.expect(!fixture.state.isPending());
}

test "capacity rejection closes the socket after rearming acceptance" {
    var fixture: Fixture = .{};
    fixture.capture.capacity_available = false;
    var coordinator = fixture.coordinator();

    try coordinator.handle(.{ .id = 4 });

    try expectSteps(&fixture.capture, &.{ .stopping, .rearm_accept, .capacity, .deinit_connection });
    try std.testing.expectEqualSlices(u8, &.{4}, fixture.capture.deinitialized_ids[0..fixture.capture.deinitialized_count]);
    try std.testing.expect(!fixture.state.isPending());
}

test "an idle admission slot transfers socket ownership to one handshake" {
    var fixture: Fixture = .{};
    var coordinator = fixture.coordinator();

    try coordinator.handle(.{ .id = 5 });

    try expectSteps(&fixture.capture, &.{ .stopping, .rearm_accept, .capacity, .start_handshake });
    try std.testing.expect(fixture.state.isPending());
    try std.testing.expectEqual(@as(?u8, 5), fixture.capture.started_id);
    try std.testing.expect(fixture.capture.start_received_slot);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.deinitialized_count);
}

test "handshake scheduling failure releases and closes the claimed socket" {
    var fixture: Fixture = .{};
    fixture.capture.handshake_failure = true;
    var coordinator = fixture.coordinator();

    try coordinator.handle(.{ .id = 6 });

    try expectSteps(&fixture.capture, &.{ .stopping, .rearm_accept, .capacity, .start_handshake, .deinit_connection });
    try std.testing.expect(fixture.capture.start_received_slot);
    try std.testing.expectEqualSlices(u8, &.{6}, fixture.capture.deinitialized_ids[0..fixture.capture.deinitialized_count]);
    try std.testing.expect(!fixture.state.isPending());
}

test "a new socket aborts a stalled handshake but does not replace its slot" {
    var fixture: Fixture = .{};
    fixture.state.begin(.{ .id = 7 });
    var coordinator = fixture.coordinator();

    try coordinator.handle(.{ .id = 8 });

    try expectSteps(&fixture.capture, &.{ .stopping, .rearm_accept, .shutdown_connection, .deinit_connection });
    try std.testing.expectEqual(@as(?u8, 7), fixture.capture.shutdown_id);
    try std.testing.expectEqualSlices(u8, &.{8}, fixture.capture.deinitialized_ids[0..fixture.capture.deinitialized_count]);
    try std.testing.expect(fixture.state.isPending());
    try std.testing.expectEqual(@as(u8, 7), fixture.state.pendingConnection().?.id);
}

pub const HandshakeStep = enum {
    stopping,
    deinit_connection,
    admit,
    start_receive,
    drop_session,
};

const test_handshake_port: GenericHandshakePort(HandshakeCapture, TestHandshakeTypes) = .{
    .stopping = HandshakeCapture.stopping,
    .deinit_connection = HandshakeCapture.deinitConnection,
    .admit = HandshakeCapture.admit,
    .start_receive = HandshakeCapture.startReceive,
    .drop_session = HandshakeCapture.dropSession,
};

pub const TestHandshakeCoordinator = GenericHandshakeCoordinator(HandshakeCapture, TestHandshakeTypes, test_handshake_port);

fn expectHandshakeSteps(capture: *const HandshakeCapture, expected: []const HandshakeStep) !void {
    try std.testing.expectEqualSlices(HandshakeStep, expected, capture.steps[0..capture.len]);
}

test "a failed handshake releases the slot and closes its connection" {
    var fixture: HandshakeFixture = .{};
    var coordinator = fixture.coordinator(1);

    coordinator.handle(error.IncompatibleProtocol);

    try expectHandshakeSteps(&fixture.capture, &.{.deinit_connection});
    try std.testing.expect(fixture.capture.effects_saw_idle);
    try std.testing.expectEqual(@as(?u8, 1), fixture.capture.deinitialized_id);
    try std.testing.expect(!fixture.state.isPending());
}

test "shutdown after negotiation closes the connection without admitting it" {
    var fixture: HandshakeFixture = .{};
    fixture.capture.runtime_stopping = true;
    var coordinator = fixture.coordinator(2);

    coordinator.handle({});

    try expectHandshakeSteps(&fixture.capture, &.{ .stopping, .deinit_connection });
    try std.testing.expect(fixture.capture.effects_saw_idle);
    try std.testing.expectEqual(@as(?u8, 2), fixture.capture.deinitialized_id);
}

test "session admission failure leaves connection ownership with the coordinator" {
    var fixture: HandshakeFixture = .{};
    fixture.capture.admission_failure = true;
    var coordinator = fixture.coordinator(3);

    coordinator.handle({});

    try expectHandshakeSteps(&fixture.capture, &.{ .stopping, .admit, .deinit_connection });
    try std.testing.expect(fixture.capture.effects_saw_idle);
    try std.testing.expectEqual(@as(?u8, 3), fixture.capture.admitted_id);
    try std.testing.expectEqual(@as(?u8, 3), fixture.capture.deinitialized_id);
}

test "successful admission transfers ownership before scheduling the first read" {
    var fixture: HandshakeFixture = .{};
    var coordinator = fixture.coordinator(4);

    coordinator.handle({});

    try expectHandshakeSteps(&fixture.capture, &.{ .stopping, .admit, .start_receive });
    try std.testing.expect(fixture.capture.effects_saw_idle);
    try std.testing.expectEqual(@as(?u8, 4), fixture.capture.admitted_id);
    try std.testing.expectEqual(@as(?u8, 14), fixture.capture.started_session);
    try std.testing.expectEqual(@as(?u8, null), fixture.capture.deinitialized_id);
    try std.testing.expectEqual(@as(?u8, null), fixture.capture.dropped_session);
}

test "first-read scheduling failure drops the admitted session" {
    var fixture: HandshakeFixture = .{};
    fixture.capture.receive_failure = true;
    var coordinator = fixture.coordinator(5);

    coordinator.handle({});

    try expectHandshakeSteps(&fixture.capture, &.{ .stopping, .admit, .start_receive, .drop_session });
    try std.testing.expect(fixture.capture.effects_saw_idle);
    try std.testing.expectEqual(@as(?u8, 15), fixture.capture.started_session);
    try std.testing.expectEqual(@as(?u8, 15), fixture.capture.dropped_session);
    try std.testing.expectEqual(@as(?u8, null), fixture.capture.deinitialized_id);
}
