//! Coordination for asynchronous pane history and agent observation.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const history = @import("../../history/root.zig");
const pane_mod = @import("../../pane/root.zig");
const agent_process = @import("../../process/root.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;
const test_support = @import("../tests/support.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Work = struct {
    pane: *Pane,
    current_size: schema.TerminalSize,
    process_cache: agent_process.Cache,
};

pub const Completion = struct {
    pane: PaneKey,
    stats: history.observer.Stats,
    process_probe: agent_process.Probe,
};

pub const Resources = struct {
    io: Io,
    panes: *PaneStore,
    agents: *agent_mod.Tracker,
    metrics: *RuntimeMetrics,
};

const ProcessReconciliation = struct {
    pane: *Pane,
    probe: agent_process.Probe,
    transition: pane_mod.HistoryObservationCompletion,
};

const ScreenReconciliation = struct {
    pane: *Pane,
    stats: history.observer.Stats,
    shell_foreground: bool,
};

/// Defines observation actor startup and runtime-owned projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Work) anyerror!void,
        publish_sound: *const fn (*Context, schema.AgentSoundNotification) void,
        schedule_description: *const fn (*Context) void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched observation coordinator.
///
/// ```zig
/// const ObservationCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane, agent, and telemetry stores.
        ///
        /// ```zig
        /// var coordinator = ObservationCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one history observation actor. Async-start failure
        /// releases the pane and sealed-batch borrow.
        ///
        /// ```zig
        /// try coordinator.schedule(pane);
        /// ```
        pub fn schedule(coordinator: *Self, pane: *Pane) !void {
            const borrow = pane.beginHistoryObservation() orelse return;
            const work: Work = .{
                .pane = pane,
                .current_size = borrow.current_size,
                .process_cache = borrow.process_cache,
            };

            port.start(coordinator.context, work) catch |err| {
                pane.cancelHistoryObservation();
                return err;
            };
        }

        /// Applies one generation-matched completion, reconciles process and
        /// screen evidence, publishes exact status-transition sounds, then
        /// rearms pending observation work before lifecycle effects.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: Completion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            const transition = pane.completeHistoryObservation(completion.process_probe.cache);
            if (transition.cwd_changed) {
                coordinator.resources.agents.touch();
            }

            coordinator.observeProcessMetrics(completion.process_probe);
            coordinator.reconcileProcess(.{
                .pane = pane,
                .probe = completion.process_probe,
                .transition = transition,
            });
            coordinator.observeHistoryMetrics(completion.stats);
            coordinator.reconcileScreen(.{
                .pane = pane,
                .stats = completion.stats,
                .shell_foreground = transition.shell_foreground,
            });

            port.schedule_description(coordinator.context);
            try coordinator.schedule(pane);
            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }

        fn observeProcessMetrics(coordinator: *Self, probe: agent_process.Probe) void {
            if (comptime !diagnostics.enabled) {
                return;
            }

            if (!probe.inspected) {
                return;
            }

            coordinator.resources.metrics.agent_process_inspections +|= 1;
            if (probe.cache.provider == .unknown) {
                coordinator.resources.metrics.agent_process_misses +|= 1;
            }
        }

        fn reconcileProcess(coordinator: *Self, reconciliation: ProcessReconciliation) void {
            if (!reconciliation.probe.changed) {
                return;
            }

            if (reconciliation.probe.cache.provider != .unknown) {
                _ = coordinator.resources.agents.observeProcess(.{
                    .identity = agent_mod.Identity.fromPane(reconciliation.pane),
                    .provider = reconciliation.probe.cache.provider,
                    .process_id = reconciliation.probe.cache.process_group_id.?,
                    .observed_at_ms = coordinator.nowMs(),
                });
                return;
            }

            if (reconciliation.transition.shell_foreground) {
                _ = coordinator.resources.agents.remove(reconciliation.pane.key());
                return;
            }

            if (reconciliation.transition.previous_process.provider != .unknown) {
                _ = coordinator.resources.agents.clearProcess(reconciliation.pane.key());
            }
        }

        fn observeHistoryMetrics(coordinator: *Self, stats: history.observer.Stats) void {
            if (comptime !diagnostics.enabled) {
                return;
            }

            coordinator.resources.metrics.history_candidate_input_bytes +|= stats.input_bytes;
            coordinator.resources.metrics.history_captured +|= stats.captured;
            coordinator.resources.metrics.history_dropped +|= stats.dropped;

            if (stats.failed) {
                coordinator.resources.metrics.history_observation_failures +|= 1;
            }

            if (stats.reset) {
                coordinator.resources.metrics.history_observation_resets +|= 1;
            }
        }

        fn reconcileScreen(coordinator: *Self, reconciliation: ScreenReconciliation) void {
            const signal = reconciliation.stats.agent_signal orelse return;
            if (reconciliation.shell_foreground) {
                return;
            }

            const identity = agent_mod.Identity.fromPane(reconciliation.pane);
            const previous_status = coordinator.resources.agents.projectedStatus(identity.key);
            const changed = coordinator.resources.agents.observeScreen(.{
                .identity = identity,
                .signal = signal,
                .observed_at_ms = coordinator.nowMs(),
            });
            if (!changed) {
                return;
            }

            const sound = soundForTransition(
                previous_status,
                coordinator.resources.agents.projectedStatus(identity.key),
            ) orelse return;
            port.publish_sound(coordinator.context, .{
                .pane_id = identity.key.id,
                .pane_generation = identity.key.generation,
                .sound = sound,
            });
        }

        fn nowMs(coordinator: *const Self) i64 {
            return Io.Timestamp.now(coordinator.resources.io, .real).toMilliseconds();
        }
    };
}

fn soundForTransition(previous: ?schema.AgentStatus, current: ?schema.AgentStatus) ?schema.AgentSound {
    if (previous != .working) {
        return null;
    }

    return switch (current orelse return null) {
        .ready => .ready,
        .blocked => .needs_input,
        .unknown, .working, .failed => null,
    };
}

const Step = enum {
    sound,
    description,
    observation,
    collect,
    pump_clients,
};

const Capture = struct {
    steps: [5]Step = undefined,
    len: usize = 0,
    start_failure: bool = false,
    started_work: ?Work = null,
    start_saw_borrow: bool = false,
    sound: ?schema.AgentSoundNotification = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn start(capture: *Capture, work: Work) !void {
        capture.record(.observation);
        capture.started_work = work;
        capture.start_saw_borrow = work.pane.history_observer.worker != null and work.pane.actor_count != 0;

        if (capture.start_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn publishSound(capture: *Capture, notification: schema.AgentSoundNotification) void {
        capture.record(.sound);
        capture.sound = notification;
    }

    fn scheduleDescription(capture: *Capture) void {
        capture.record(.description);
    }

    fn collect(capture: *Capture) void {
        capture.record(.collect);
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }
};

const test_port: RuntimePort(Capture) = .{
    .start = Capture.start,
    .publish_sound = Capture.publishSound,
    .schedule_description = Capture.scheduleDescription,
    .collect = Capture.collect,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn testCoordinator(capture: *Capture, fixture: *test_support.PaneFixture, panes: *PaneStore) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .agents = &fixture.agents,
        .metrics = &fixture.metrics,
    });
}

fn beginFixtureObservation(fixture: *test_support.PaneFixture, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    fixture.pane.queueHistoryOutput(.{ .bytes = "observed", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
}

fn queueFollowUp(fixture: *test_support.PaneFixture) void {
    fixture.pane.queueHistoryOutput(.{ .bytes = "follow-up", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
}

fn processCache(provider: schema.AgentProvider, process_id: u32, executable: []const u8) agent_process.Cache {
    var cache = agent_process.Cache.init(executable);
    cache.process_group_id = process_id;
    cache.provider = provider;
    return cache;
}

fn nonShellProcessId(pane: *const Pane) u32 {
    const shell = std.math.cast(u32, pane.session.pid) orelse 1;
    return if (shell == std.math.maxInt(u32)) shell - 1 else shell + 1;
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

const ExpectedMetrics = struct {
    inspections: u64 = 0,
    misses: u64 = 0,
    input_bytes: u64 = 0,
    captured: u64 = 0,
    dropped: u64 = 0,
    failures: u64 = 0,
    resets: u64 = 0,
};

fn expectMetrics(metrics: *const RuntimeMetrics, expected: ExpectedMetrics) !void {
    const actual = if (comptime diagnostics.enabled) expected else ExpectedMetrics{};
    try std.testing.expectEqual(actual.inspections, metrics.agent_process_inspections);
    try std.testing.expectEqual(actual.misses, metrics.agent_process_misses);
    try std.testing.expectEqual(actual.input_bytes, metrics.history_candidate_input_bytes);
    try std.testing.expectEqual(actual.captured, metrics.history_captured);
    try std.testing.expectEqual(actual.dropped, metrics.history_dropped);
    try std.testing.expectEqual(actual.failures, metrics.history_observation_failures);
    try std.testing.expectEqual(actual.resets, metrics.history_observation_resets);
}

test "known process observation commits pane state agent evidence and metrics" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.history_observer.tracker.updateCwd("/observed");
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const process_id = nonShellProcessId(fixture.pane);
    const foreground_revision = fixture.pane.foreground_revision;

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{
            .input_bytes = 13,
            .captured = 2,
            .dropped = 3,
            .failed = true,
            .reset = true,
        },
        .process_probe = .{
            .cache = processCache(.claude, process_id, "Claude Code"),
            .changed = true,
            .inspected = true,
        },
    });

    try expectSteps(&capture, &.{ .description, .collect, .pump_clients });
    try std.testing.expectEqualStrings("/observed", fixture.pane.cwd.slice());
    try std.testing.expectEqual(foreground_revision + 1, fixture.pane.foreground_revision);
    try std.testing.expectEqualStrings("Claude Code", fixture.pane.agent_process_cache.name());
    try std.testing.expectEqual(schema.AgentStatus.ready, fixture.agents.projectedStatus(fixture.pane.key()).?);
    try expectMetrics(&fixture.metrics, .{
        .inspections = 1,
        .input_bytes = 13,
        .captured = 2,
        .dropped = 3,
        .failures = 1,
        .resets = 1,
    });
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expect(fixture.pane.history_observer.worker == null);
}

test "foreground revision wraps past zero when the process name changes" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.foreground_revision = std.math.maxInt(u64);
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.unknown, nonShellProcessId(fixture.pane), "different"),
        },
    });

    try std.testing.expectEqual(@as(u64, 1), fixture.pane.foreground_revision);
}

test "shell foreground removes the agent and ignores screen readiness" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const identity = agent_mod.Identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    const shell_id = std.math.cast(u32, fixture.pane.session.pid).?;

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{ .agent_signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 100,
            .identity_confirmed = true,
            .ready_confirmed = true,
        } },
        .process_probe = .{
            .cache = processCache(.unknown, shell_id, "sh"),
            .changed = true,
            .inspected = true,
        },
    });

    try expectSteps(&capture, &.{ .description, .collect, .pump_clients });
    try std.testing.expect(fixture.agents.projectedStatus(identity.key) == null);
    try std.testing.expect(capture.sound == null);
    try expectMetrics(&fixture.metrics, .{ .inspections = 1, .misses = 1 });
}

test "an unknown non-shell process clears previous process evidence" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const process_id = nonShellProcessId(fixture.pane);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.claude, process_id, "Claude Code"),
            .changed = true,
        },
    });
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) != null);

    capture = .{};
    fixture.pane.queueHistoryOutput(.{ .bytes = "next", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
    const unknown_id = if (process_id == std.math.maxInt(u32)) process_id - 1 else process_id + 1;
    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.unknown, unknown_id, "other"),
            .changed = true,
        },
    });

    try expectSteps(&capture, &.{ .description, .collect, .pump_clients });
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) == null);
}

test "working to ready screen evidence publishes one generation-safe sound" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const identity = agent_mod.Identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    try std.testing.expect(fixture.agents.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .working,
            .confidence = 100,
            .identity_confirmed = true,
        },
        .observed_at_ms = 2,
    }));

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{ .agent_signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 100,
            .identity_confirmed = true,
            .ready_confirmed = true,
        } },
        .process_probe = .{
            .cache = processCache(.codex, process_id, "Codex"),
        },
    });

    try expectSteps(&capture, &.{ .sound, .description, .collect, .pump_clients });
    try std.testing.expectEqual(schema.AgentStatus.ready, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expectEqualDeep(schema.AgentSoundNotification{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = .ready,
    }, capture.sound.?);
}

test "pending history is rearmed after description scheduling" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{ .cache = fixture.pane.agent_process_cache },
    });

    try expectSteps(&capture, &.{ .description, .observation, .collect, .pump_clients });
    try std.testing.expect(capture.start_saw_borrow);
    try std.testing.expectEqualDeep(fixture.pane.size, capture.started_work.?.current_size);
    try std.testing.expectEqualStrings(fixture.pane.agent_process_cache.name(), capture.started_work.?.process_cache.name());
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.actor_count);
    fixture.pane.cancelHistoryObservation();
}

test "observation start failure releases the sealed batch and skips lifecycle effects" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: Capture = .{ .start_failure = true };
    var coordinator = testCoordinator(&capture, &fixture, &panes);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{ .cache = fixture.pane.agent_process_cache },
    }));

    try expectSteps(&capture, &.{ .description, .observation });
    try std.testing.expect(capture.start_saw_borrow);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expect(fixture.pane.history_observer.worker == null);
    try std.testing.expect(!fixture.pane.history_observer.hasPending());
}

test "a stale generation cannot release a live observation borrow" {
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.actor_count = 1;
    pane.history_observer.worker = 1;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var agents: agent_mod.Tracker = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var coordinator = TestCoordinator.init(&capture, .{
        .io = std.testing.io,
        .panes = &panes,
        .agents = &agents,
        .metrics = &metrics,
    });

    try coordinator.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .stats = .{},
        .process_probe = .{ .cache = .{} },
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try expectSteps(&capture, &.{});
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try std.testing.expectEqual(@as(?u1, 1), pane.history_observer.worker);
}

test "sounds are restricted to working-to-ready and working-to-blocked transitions" {
    try std.testing.expectEqual(schema.AgentSound.ready, soundForTransition(.working, .ready).?);
    try std.testing.expectEqual(schema.AgentSound.needs_input, soundForTransition(.working, .blocked).?);
    try std.testing.expect(soundForTransition(null, .ready) == null);
    try std.testing.expect(soundForTransition(.ready, .ready) == null);
    try std.testing.expect(soundForTransition(.blocked, .ready) == null);
    try std.testing.expect(soundForTransition(.working, .failed) == null);
}
