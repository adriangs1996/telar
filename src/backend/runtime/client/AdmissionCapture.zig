const Capture = @This();
const source_namespace = @import("admission.zig");
const std = @import("std");
const FakeConnection = @import("FakeConnection.zig");
steps: [8]source_namespace.Step = undefined,
len: usize = 0,
runtime_stopping: bool = false,
capacity_available: bool = true,
rearm_failure: bool = false,
handshake_failure: bool = false,
state: ?*source_namespace.AdmissionState = null,
shutdown_id: ?u8 = null,
deinitialized_ids: [2]u8 = undefined,
deinitialized_count: usize = 0,
started_id: ?u8 = null,
start_received_slot: bool = false,

fn record(capture: *Capture, step: source_namespace.Step) void {
    std.debug.assert(capture.len < capture.steps.len);
    capture.steps[capture.len] = step;
    capture.len += 1;
}

pub fn stopping(capture: *Capture) bool {
    capture.record(.stopping);
    return capture.runtime_stopping;
}

pub fn rearmAccept(capture: *Capture) !void {
    capture.record(.rearm_accept);

    if (capture.rearm_failure) {
        return error.SchedulerUnavailable;
    }
}

pub fn hasCapacity(capture: *Capture) bool {
    capture.record(.capacity);
    return capture.capacity_available;
}

pub fn shutdownConnection(capture: *Capture, connection: *FakeConnection) void {
    capture.record(.shutdown_connection);
    capture.shutdown_id = connection.id;
}

pub fn deinitConnection(capture: *Capture, connection: *FakeConnection) void {
    capture.record(.deinit_connection);
    std.debug.assert(capture.deinitialized_count < capture.deinitialized_ids.len);
    capture.deinitialized_ids[capture.deinitialized_count] = connection.id;
    capture.deinitialized_count += 1;
}

pub fn startHandshake(capture: *Capture, connection: *FakeConnection) !void {
    capture.record(.start_handshake);
    capture.started_id = connection.id;
    capture.start_received_slot = connection == capture.state.?.pendingConnection().?;

    if (capture.handshake_failure) {
        return error.SchedulerUnavailable;
    }
}
