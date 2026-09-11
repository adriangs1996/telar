const HandshakeCapture = @This();
const source_namespace = @import("admission.zig");
const std = @import("std");
const FakeConnection = @import("FakeConnection.zig");
const FakeSession = @import("AdmissionFakeSession.zig");
steps: [5]source_namespace.HandshakeStep = undefined,
len: usize = 0,
runtime_stopping: bool = false,
admission_failure: bool = false,
receive_failure: bool = false,
state: ?*const source_namespace.AdmissionState = null,
effects_saw_idle: bool = true,
deinitialized_id: ?u8 = null,
admitted_id: ?u8 = null,
started_session: ?u8 = null,
dropped_session: ?u8 = null,

fn record(capture: *HandshakeCapture, step: source_namespace.HandshakeStep) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
    capture.effects_saw_idle = capture.effects_saw_idle and !capture.state.?.isPending();
}

pub fn stopping(capture: *HandshakeCapture) bool {
    capture.record(.stopping);
    return capture.runtime_stopping;
}

pub fn deinitConnection(capture: *HandshakeCapture, connection: *FakeConnection) void {
    capture.record(.deinit_connection);
    capture.deinitialized_id = connection.id;
}

pub fn admit(capture: *HandshakeCapture, connection: FakeConnection) !FakeSession {
    capture.record(.admit);
    capture.admitted_id = connection.id;

    if (capture.admission_failure) {
        return error.ClientLimitReached;
    }

    return .{ .id = connection.id + 10 };
}

pub fn startReceive(capture: *HandshakeCapture, session: FakeSession) !void {
    capture.record(.start_receive);
    capture.started_session = session.id;

    if (capture.receive_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn dropSession(capture: *HandshakeCapture, session: FakeSession) void {
    capture.record(.drop_session);
    capture.dropped_session = session.id;
}
