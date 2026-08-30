//! Coordination for one completed pane child wait.

const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const pane_mod = @import("../pane/root.zig");
const pty = @import("../pty/root.zig");
const telemetry_mod = @import("telemetry.zig");
const test_support = @import("test_support.zig");

const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Completion = struct {
    pane: PaneKey,
    result: anyerror!pty.Exit,
};

pub const Resources = struct {
    panes: *PaneStore,
    agents: *agent_mod.Tracker,
    metrics: *RuntimeMetrics,
};

/// Defines credential retirement, history scheduling, and runtime lifecycle
/// effects supplied by the composition root.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        revoke_credential: *const fn (*Context, *Pane) void,
        schedule_observation: *const fn (*Context, *Pane) anyerror!void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched pane-exit coordinator.
///
/// ```zig
/// const ExitCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var coordinator = ExitCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Commits one generation-matched exit, retires agent and credential
        /// state, and queues exit history once PTY output is already drained.
        /// Wait failures become a synthetic SIGKILL exit.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: Completion) !void {
            const transition = coordinator.resources.panes.completeExit(
                completion.pane,
                exitOrSynthetic(completion.result),
            ) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            _ = coordinator.resources.agents.remove(transition.pane.key());
            port.revoke_credential(coordinator.context, transition.pane);

            if (transition.launch_aborting) {
                port.collect(coordinator.context);
                port.pump_clients(coordinator.context);
                return;
            }

            if (transition.output_done) {
                transition.pane.queueExitedHistory(transition.exit);
                try port.schedule_observation(coordinator.context, transition.pane);
            }

            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }
    };
}

fn exitOrSynthetic(result: anyerror!pty.Exit) pty.Exit {
    return result catch .{ .signaled = .KILL };
}

const Step = enum {
    revoke_credential,
    observation,
    collect,
    pump_clients,
};

const Capture = struct {
    steps: [4]Step = undefined,
    len: usize = 0,
    observation_failure: bool = false,
    revoke_saw_exit: bool = false,
    observation_saw_history: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn revokeCredential(capture: *Capture, pane: *Pane) void {
        capture.record(.revoke_credential);
        capture.revoke_saw_exit = pane.exit != null;
    }

    fn scheduleObservation(capture: *Capture, pane: *Pane) !void {
        capture.record(.observation);
        capture.observation_saw_history = pane.history_exit_queued and pane.history_observer.hasPending();

        if (capture.observation_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn collect(capture: *Capture) void {
        capture.record(.collect);
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }
};

const test_port: RuntimePort(Capture) = .{
    .revoke_credential = Capture.revokeCredential,
    .schedule_observation = Capture.scheduleObservation,
    .collect = Capture.collect,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn testCoordinator(capture: *Capture, fixture: *test_support.PaneFixture, panes: *PaneStore) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .panes = panes,
        .agents = &fixture.agents,
        .metrics = &fixture.metrics,
    });
}

fn beginFixtureExit(fixture: *test_support.PaneFixture, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    try std.testing.expect(fixture.pane.beginExitWait());
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "a running pane exit retires agent and credential before lifecycle effects" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    const identity = agent_mod.Identity.fromPane(fixture.pane);
    const shell_id = std.math.cast(u32, fixture.pane.session.pid).?;
    const process_id = if (shell_id == std.math.maxInt(u32)) shell_id - 1 else shell_id + 1;
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = pty.Exit{ .exited = 7 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .collect, .pump_clients });
    try std.testing.expect(capture.revoke_saw_exit);
    try std.testing.expectEqual(pty.Exit{ .exited = 7 }, fixture.pane.exit.?);
    try std.testing.expect(!fixture.pane.wait_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
    try std.testing.expect(fixture.agents.projectedStatus(identity.key) == null);
    try std.testing.expect(!fixture.pane.history_exit_queued);
}

test "drained output queues exit history before observation" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = pty.Exit{ .exited = 0 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .observation, .collect, .pump_clients });
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(fixture.pane.history_exit_queued);
}

test "an aborting launch skips exit history even after output drains" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.launch_state = .aborting;
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = pty.Exit{ .exited = 1 },
    });

    try expectSteps(&capture, &.{ .revoke_credential, .collect, .pump_clients });
    try std.testing.expect(!fixture.pane.history_exit_queued);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
}

test "exit observation failure preserves retirement and skips lifecycle effects" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.finishPtyOutput();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: Capture = .{ .observation_failure = true };
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = pty.Exit{ .exited = 0 },
    }));

    try expectSteps(&capture, &.{ .revoke_credential, .observation });
    try std.testing.expect(fixture.pane.history_exit_queued);
    try std.testing.expectEqual(@as(usize, 1), panes.exited_count);
}

test "wait failure commits a synthetic SIGKILL exit" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureExit(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = error.WaitpidFailed,
    });

    try std.testing.expectEqual(pty.Exit{ .signaled = .KILL }, fixture.pane.exit.?);
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
    var agents: agent_mod.Tracker = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var coordinator = TestCoordinator.init(&capture, .{
        .panes = &panes,
        .agents = &agents,
        .metrics = &metrics,
    });

    try coordinator.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = pty.Exit{ .exited = 0 },
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try expectSteps(&capture, &.{});
    try std.testing.expect(pane.wait_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try std.testing.expectEqual(@as(usize, 0), panes.exited_count);
}

test "wait failure becomes a synthetic SIGKILL exit" {
    try std.testing.expectEqual(
        pty.Exit{ .signaled = .KILL },
        exitOrSynthetic(error.WaitpidFailed),
    );
    try std.testing.expectEqual(
        pty.Exit{ .exited = 7 },
        exitOrSynthetic(pty.Exit{ .exited = 7 }),
    );
}
