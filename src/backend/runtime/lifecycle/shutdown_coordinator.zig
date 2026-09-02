//! Ordered, idempotent teardown for one composed runtime.

const std = @import("std");

pub const State = enum {
    running,
    shutting_down,
    stopped,
};

pub const Step = enum {
    stop_listener,
    stop_client_connections,
    stop_pending_admission,
    stop_panes,
    cancel_actors,
    destroy_proxy,
    destroy_listener,
    destroy_pending_admission,
    release_client_actor_claims,
    destroy_client_sessions,
    destroy_panes,
    destroy_workspaces,
    destroy_engine,
    destroy_history,
    destroy_client_store,
    destroy_telemetry,
    destroy_child_environment,
};

const shutdown_order = [_]Step{
    .stop_listener,
    .stop_client_connections,
    .stop_pending_admission,
    .stop_panes,
    .cancel_actors,
    .destroy_proxy,
    .destroy_listener,
    .destroy_pending_admission,
    .release_client_actor_claims,
    .destroy_client_sessions,
    .destroy_panes,
    .destroy_workspaces,
    .destroy_engine,
    .destroy_history,
    .destroy_client_store,
    .destroy_telemetry,
    .destroy_child_environment,
};

pub fn Coordinator(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: *Context,
        state: *State,
        execute_fn: *const fn (*Context, Step) void,

        /// Binds one runtime and its lifecycle state to a concrete step
        /// executor. The coordinator does not own either borrow.
        ///
        /// ```zig
        /// var shutdown = Coordinator(Runtime).init(&runtime, &state, executeStep);
        /// ```
        pub fn init(context: *Context, state: *State, execute_fn: *const fn (*Context, Step) void) Self {
            return .{ .context = context, .state = state, .execute_fn = execute_fn };
        }

        /// Executes the complete teardown order at most once. The state moves
        /// to `shutting_down` before the first effect, so recursive calls are
        /// harmless, and reaches `stopped` only after the last effect.
        ///
        /// ```zig
        /// shutdown.run();
        /// ```
        pub fn run(coordinator: *Self) void {
            if (coordinator.state.* != .running) {
                return;
            }

            coordinator.state.* = .shutting_down;
            for (shutdown_order) |step| {
                coordinator.execute_fn(coordinator.context, step);
            }
            coordinator.state.* = .stopped;
        }
    };
}

const Capture = struct {
    state: *const State,
    steps: [shutdown_order.len]Step = undefined,
    len: usize = 0,
    observed_wrong_state: bool = false,
    coordinator: ?*Coordinator(Capture) = null,
    reenter: bool = false,

    fn execute(capture: *Capture, step: Step) void {
        if (capture.state.* != .shutting_down) {
            capture.observed_wrong_state = true;
        }

        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;

        if (capture.reenter and capture.len == 1) {
            capture.coordinator.?.run();
        }
    }
};

const TestCoordinator = Coordinator(Capture);

fn expectShutdownOrder(capture: *const Capture) !void {
    const expected = [_]Step{
        .stop_listener,
        .stop_client_connections,
        .stop_pending_admission,
        .stop_panes,
        .cancel_actors,
        .destroy_proxy,
        .destroy_listener,
        .destroy_pending_admission,
        .release_client_actor_claims,
        .destroy_client_sessions,
        .destroy_panes,
        .destroy_workspaces,
        .destroy_engine,
        .destroy_history,
        .destroy_client_store,
        .destroy_telemetry,
        .destroy_child_environment,
    };

    try std.testing.expectEqualSlices(Step, &expected, capture.steps[0..capture.len]);
}

test "shutdown executes every step once in dependency order" {
    var state: State = .running;
    var capture: Capture = .{ .state = &state };
    var coordinator = TestCoordinator.init(&capture, &state, Capture.execute);

    coordinator.run();

    try std.testing.expectEqual(State.stopped, state);
    try std.testing.expect(!capture.observed_wrong_state);
    try expectShutdownOrder(&capture);
}

test "shutdown order contains every declared step exactly once" {
    try std.testing.expectEqual(std.enums.values(Step).len, shutdown_order.len);

    for (std.enums.values(Step)) |expected| {
        var count: usize = 0;
        for (shutdown_order) |actual| {
            if (actual == expected) {
                count += 1;
            }
        }

        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "shutdown is idempotent after completion" {
    var state: State = .running;
    var capture: Capture = .{ .state = &state };
    var coordinator = TestCoordinator.init(&capture, &state, Capture.execute);

    coordinator.run();
    coordinator.run();

    try std.testing.expectEqual(shutdown_order.len, capture.len);
    try std.testing.expectEqual(State.stopped, state);
}

test "recursive shutdown cannot duplicate or reorder effects" {
    var state: State = .running;
    var capture: Capture = .{ .state = &state, .reenter = true };
    var coordinator = TestCoordinator.init(&capture, &state, Capture.execute);
    capture.coordinator = &coordinator;

    coordinator.run();

    try expectShutdownOrder(&capture);
    try std.testing.expectEqual(State.stopped, state);
}
