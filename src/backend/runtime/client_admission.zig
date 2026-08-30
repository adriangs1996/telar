//! Single-flight admission of accepted client sockets.

const std = @import("std");

/// Creates the runtime-owned slot borrowed by one in-flight handshake actor.
///
/// ```zig
/// const AdmissionState = State(Connection);
/// var state: AdmissionState = .{};
/// ```
pub fn State(comptime Connection: type) type {
    return struct {
        const Self = @This();

        slot: ?Connection = null,
        pending: bool = false,

        /// Reports whether a handshake actor still borrows the connection.
        ///
        /// ```zig
        /// if (state.isPending()) return;
        /// ```
        pub fn isPending(state: *const Self) bool {
            return state.pending;
        }

        /// Returns the connection borrowed by the active handshake, if any.
        /// Shutdown may use it to unblock the actor but must not deinitialize it.
        ///
        /// ```zig
        /// if (state.pendingConnection()) |connection| connection.shutdown(io);
        /// ```
        pub fn pendingConnection(state: *Self) ?*Connection {
            if (!state.pending) {
                return null;
            }

            return &state.slot.?;
        }

        /// Transfers the pending connection out after its actor has completed
        /// or failed to start, leaving the slot idle for the next admission.
        ///
        /// ```zig
        /// var connection = state.takePending();
        /// defer connection.deinit(io);
        /// ```
        pub fn takePending(state: *Self) Connection {
            std.debug.assert(state.pending and state.slot != null);
            const connection = state.slot.?;
            state.slot = null;
            state.pending = false;
            return connection;
        }

        fn begin(state: *Self, connection: Connection) void {
            std.debug.assert(!state.pending and state.slot == null);
            state.slot = connection;
            state.pending = true;
        }
    };
}

/// Defines shutdown policy and socket effects supplied by the runtime
/// composition root.
///
/// ```zig
/// const port: AcceptPort(Context, Connection) = .{ ... };
/// ```
pub fn AcceptPort(comptime Context: type, comptime Connection: type) type {
    return struct {
        stopping: *const fn (*Context) bool,
        rearm_accept: *const fn (*Context) anyerror!void,
        has_capacity: *const fn (*Context) bool,
        shutdown_connection: *const fn (*Context, *Connection) void,
        deinit_connection: *const fn (*Context, *Connection) void,
        start_handshake: *const fn (*Context, *Connection) anyerror!void,
    };
}

/// Creates a statically dispatched accepted-socket coordinator.
///
/// ```zig
/// const AcceptedCoordinator = AcceptCoordinator(Context, Connection, port);
/// ```
pub fn AcceptCoordinator(comptime Context: type, comptime Connection: type, comptime port: AcceptPort(Context, Connection)) type {
    return struct {
        const Self = @This();
        const ConnectionState = State(Connection);

        context: *Context,
        state: *ConnectionState,

        /// Binds accepted-socket effects to the runtime's handshake slot.
        ///
        /// ```zig
        /// var coordinator = AcceptedCoordinator.init(&context, &state);
        /// ```
        pub fn init(context: *Context, state: *ConnectionState) Self {
            return .{ .context = context, .state = state };
        }

        /// Rearms acceptance before starting one handshake actor. Every socket
        /// stays owned by either this call or the handshake slot; shutdown,
        /// capacity, rearm, and scheduling failures close the unclaimed socket.
        /// A new arrival aborts a stalled handshake but cannot reuse its slot
        /// until that actor completes.
        ///
        /// ```zig
        /// try coordinator.handle(accepted_result);
        /// ```
        pub fn handle(coordinator: *Self, result: anyerror!Connection) !void {
            var accepted = result catch {
                try port.rearm_accept(coordinator.context);
                return;
            };
            var accepted_owned = true;
            defer if (accepted_owned) {
                port.deinit_connection(coordinator.context, &accepted);
            };

            if (port.stopping(coordinator.context)) {
                return;
            }

            try port.rearm_accept(coordinator.context);

            if (coordinator.state.isPending()) {
                port.shutdown_connection(coordinator.context, coordinator.state.pendingConnection().?);
                return;
            }

            if (!port.has_capacity(coordinator.context)) {
                return;
            }

            coordinator.state.begin(accepted);
            accepted_owned = false;
            port.start_handshake(coordinator.context, coordinator.state.pendingConnection().?) catch {
                var unstarted = coordinator.state.takePending();
                port.deinit_connection(coordinator.context, &unstarted);
            };
        }
    };
}

const FakeConnection = struct {
    id: u8,
};

const AdmissionState = State(FakeConnection);

const Step = enum {
    stopping,
    rearm_accept,
    capacity,
    shutdown_connection,
    deinit_connection,
    start_handshake,
};

const Capture = struct {
    steps: [8]Step = undefined,
    len: usize = 0,
    runtime_stopping: bool = false,
    capacity_available: bool = true,
    rearm_failure: bool = false,
    handshake_failure: bool = false,
    state: ?*AdmissionState = null,
    shutdown_id: ?u8 = null,
    deinitialized_ids: [2]u8 = undefined,
    deinitialized_count: usize = 0,
    started_id: ?u8 = null,
    start_received_slot: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn stopping(capture: *Capture) bool {
        capture.record(.stopping);
        return capture.runtime_stopping;
    }

    fn rearmAccept(capture: *Capture) !void {
        capture.record(.rearm_accept);

        if (capture.rearm_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn hasCapacity(capture: *Capture) bool {
        capture.record(.capacity);
        return capture.capacity_available;
    }

    fn shutdownConnection(capture: *Capture, connection: *FakeConnection) void {
        capture.record(.shutdown_connection);
        capture.shutdown_id = connection.id;
    }

    fn deinitConnection(capture: *Capture, connection: *FakeConnection) void {
        capture.record(.deinit_connection);
        std.debug.assert(capture.deinitialized_count < capture.deinitialized_ids.len);
        capture.deinitialized_ids[capture.deinitialized_count] = connection.id;
        capture.deinitialized_count += 1;
    }

    fn startHandshake(capture: *Capture, connection: *FakeConnection) !void {
        capture.record(.start_handshake);
        capture.started_id = connection.id;
        capture.start_received_slot = connection == capture.state.?.pendingConnection().?;

        if (capture.handshake_failure) {
            return error.SchedulerUnavailable;
        }
    }
};

const test_port: AcceptPort(Capture, FakeConnection) = .{
    .stopping = Capture.stopping,
    .rearm_accept = Capture.rearmAccept,
    .has_capacity = Capture.hasCapacity,
    .shutdown_connection = Capture.shutdownConnection,
    .deinit_connection = Capture.deinitConnection,
    .start_handshake = Capture.startHandshake,
};

const TestCoordinator = AcceptCoordinator(Capture, FakeConnection, test_port);

const Fixture = struct {
    state: AdmissionState = .{},
    capture: Capture = .{},

    fn coordinator(fixture: *Fixture) TestCoordinator {
        fixture.capture.state = &fixture.state;
        return TestCoordinator.init(&fixture.capture, &fixture.state);
    }
};

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
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
