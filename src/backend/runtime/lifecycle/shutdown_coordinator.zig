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
    destroy_plugins,
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

pub const shutdown_order = [_]Step{
    .stop_listener,
    .stop_client_connections,
    .stop_pending_admission,
    .stop_panes,
    .cancel_actors,
    .destroy_proxy,
    .destroy_plugins,
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

pub const Coordinator = @import("GenericShutdownCoordinatorCoordinator.zig").Type;

const Capture = @import("Capture.zig");

const TestCoordinator = Coordinator(Capture);

fn expectShutdownOrder(capture: *const Capture) !void {
    const expected = [_]Step{
        .stop_listener,
        .stop_client_connections,
        .stop_pending_admission,
        .stop_panes,
        .cancel_actors,
        .destroy_proxy,
        .destroy_plugins,
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
