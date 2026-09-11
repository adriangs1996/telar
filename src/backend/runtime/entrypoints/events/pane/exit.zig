//! Coordination for one completed pane child wait.

const exit_module = @import("../../../../pty/exit.zig");
const GenericExitRuntimePort = @import("GenericExitRuntimePort.zig").Type;
const ExitCapture = @import("ExitCapture.zig");
const GenericExitCoordinator = @import("GenericExitCoordinator.zig").Type;
const PaneFixtureType = @import("../../../tests/PaneFixture.zig");
const PaneStore = @import("../../../../pane/PaneStore.zig");
const std = @import("std");
const agent_identity = @import("../../../application/coordinators/agent_identity.zig");
const Pane = @import("../../../../pane/Pane.zig");
const TrackerType = @import("../../../../agent/Tracker.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");

pub fn exitOrSynthetic(result: anyerror!exit_module.Exit) exit_module.Exit {
    return result catch .{ .signaled = .KILL };
}

pub const Step = enum {
    revoke_credential,
    observation,
    collect,
    pump_clients,
};

const test_port: GenericExitRuntimePort(ExitCapture) = .{
    .revoke_credential = ExitCapture.revokeCredential,
    .schedule_observation = ExitCapture.scheduleObservation,
    .collect = ExitCapture.collect,
    .pump_clients = ExitCapture.pumpClients,
};

const TestCoordinator = GenericExitCoordinator(ExitCapture, test_port);

fn testCoordinator(capture: *ExitCapture, fixture: *PaneFixtureType, panes: *PaneStore) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .panes = panes,
        .agents = &fixture.agents,
        .metrics = &fixture.metrics,
    });
}

fn beginFixtureExit(fixture: *PaneFixtureType, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    try std.testing.expect(fixture.pane.beginExitWait());
}

fn expectSteps(capture: *const ExitCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a running pane exit retires agent and credential before lifecycle effects" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    const identity = agent_identity.fromPane(fixture.pane);
    const shell_id = std.math.cast(u32, fixture.pane.session.processId()).?;
    const process_id = if (shell_id == std.math.maxInt(u32)) shell_id - 1 else shell_id + 1;
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    var capture: ExitCapture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = exit_module.Exit{ .exited = 7 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .collect, .pump_clients });
    try std.testing.expect(capture.revoke_saw_exit);
    try std.testing.expectEqual(exit_module.Exit{ .exited = 7 }, fixture.pane.exit.?);
    try std.testing.expect(!fixture.pane.wait_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
    try std.testing.expect(fixture.agents.projectedStatus(identity.key) == null);
    try std.testing.expect(!fixture.pane.history_exit_queued);
}

test "drained output queues exit history before observation" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: ExitCapture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = exit_module.Exit{ .exited = 0 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .observation, .collect, .pump_clients });
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(fixture.pane.history_exit_queued);
}

test "an aborting launch skips exit history even after output drains" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.launch_state = .aborting;
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: ExitCapture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = exit_module.Exit{ .exited = 1 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .collect, .pump_clients });
    try std.testing.expect(!fixture.pane.history_exit_queued);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
}

test "exit observation failure preserves retirement and skips lifecycle effects" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: ExitCapture = .{ .observation_failure = true };
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = exit_module.Exit{ .exited = 0 },
    }));

    try expectSteps(&capture, &.{ .revoke_credential, .observation });
    try std.testing.expect(fixture.pane.history_exit_queued);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
}

test "wait failure commits a synthetic SIGKILL exit" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: ExitCapture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = error.WaitpidFailed,
    });

    try std.testing.expectEqual(exit_module.Exit{ .signaled = .KILL }, fixture.pane.exit.?);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
}

test "a stale generation cannot release a live wait borrow" {
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.wait_pending = true;
    pane.actor_count = 1;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var agents: TrackerType = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ExitCapture = .{};
    var coordinator = TestCoordinator.init(&capture, .{
        .panes = &panes,
        .agents = &agents,
        .metrics = &metrics,
    });

    try coordinator.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = exit_module.Exit{ .exited = 0 },
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try expectSteps(&capture, &.{});
    try std.testing.expect(pane.wait_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try std.testing.expectEqual(@as(usize, 0), panes.exited_count);
}

test "wait failure becomes a synthetic SIGKILL exit" {
    try std.testing.expectEqual(
        exit_module.Exit{ .signaled = .KILL },
        exitOrSynthetic(error.WaitpidFailed),
    );
    try std.testing.expectEqual(
        exit_module.Exit{ .exited = 7 },
        exitOrSynthetic(exit_module.Exit{ .exited = 7 }),
    );
}
