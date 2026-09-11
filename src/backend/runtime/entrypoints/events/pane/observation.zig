//! Coordination for asynchronous pane history and agent observation.

const std = @import("std");
const agent_identity = @import("../../../application/coordinators/root.zig").agent_identity;
const core = @import("telar-core");
const agent_mod = @import("../../../../agent/root.zig");
const history = @import("../../../../history/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const agent_process = @import("../../../../process/root.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;
const test_support = @import("../../../tests/support.zig");

pub const Io = std.Io;
pub const diagnostics = core.diagnostics;
pub const schema = core.schema;
pub const Pane = pane_mod.Pane;
pub const PaneKey = pane_mod.PaneKey;
pub const PaneStore = pane_mod.PaneStore;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Work = @import("ObservationWork.zig");

pub const Completion = @import("ObservationCompletion.zig");

pub const Resources = @import("ObservationResources.zig");

const ProcessReconciliation = @import("ProcessReconciliation.zig");

const ScreenReconciliation = @import("ScreenReconciliation.zig");

pub const RuntimePort = @import("GenericObservationRuntimePort.zig").Type;

pub const Coordinator = @import("GenericObservationCoordinator.zig").Type;

pub const soundForTransition = agent_mod.soundForTransition;

pub const Step = enum {
    sound,
    description,
    observation,
    collect,
    pump_clients,
};

const Capture = @import("ObservationCapture.zig");

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
    const shell = std.math.cast(u32, pane.session.processId()) orelse 1;
    return if (shell == std.math.maxInt(u32)) shell - 1 else shell + 1;
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

const ExpectedMetrics = @import("ObservationExpectedMetrics.zig");

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
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    const shell_id = std.math.cast(u32, fixture.pane.session.processId()).?;

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{ .agent_observation = .{ .observed_at_ms = 3, .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 100,
            .identity_confirmed = true,
            .ready_confirmed = true,
        } } },
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
    const identity = agent_identity.fromPane(fixture.pane);
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
        .stats = .{ .agent_observation = .{ .observed_at_ms = 3, .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 100,
            .identity_confirmed = true,
            .ready_confirmed = true,
        } } },
        .process_probe = .{
            .cache = processCache(.codex, process_id, "Codex"),
        },
    });

    try expectSteps(&capture, &.{ .sound, .description, .collect, .pump_clients });
    try std.testing.expectEqual(schema.AgentStatus.done, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expectEqualDeep(schema.AgentSoundNotification{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = .ready,
    }, capture.sound.?);
}

test "a delayed screen completion cannot settle a newer Codex Stop or publish a sound" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    _ = fixture.agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = process_id, .observed_at_ms = 100 });
    _ = fixture.agents.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 300 });

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{ .agent_observation = .{
            .observed_at_ms = 200,
            .signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true },
        } },
        .process_probe = .{ .cache = processCache(.codex, process_id, "Codex") },
    });

    try std.testing.expectEqual(schema.AgentStatus.working, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expect(capture.sound == null);
}

test "Codex PTY frames and continuing Stop hooks publish exactly one final completion sound" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const size: schema.TerminalSize = .{ .cols = 100, .rows = 16 };
    fixture.pane.history_observer.queueResize(size);
    var panes: PaneStore = .{};
    try panes.insert(fixture.pane);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    _ = fixture.agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = process_id, .observed_at_ms = 50 });

    const cases = [_]struct {
        report: ?schema.AgentReportState,
        now_ms: i64,
        output: []const u8,
        status: schema.AgentStatus,
        sound: bool = false,
    }{
        .{ .report = .working, .now_ms = 100, .output = "\x1b[1;1HWorking (1s)\x1b[4;1H\xe2\x80\xba Ask Codex to do anything\x1b[4;3H", .status = .working },
        .{ .report = .settling, .now_ms = 200, .output = "\x1b[?2026h\x1b[1;1H\x1b[2K\x1b[4;3H", .status = .working },
        .{ .report = .working, .now_ms = 300, .output = "\x1b[1;1HWorking (2s)\x1b[4;3H\x1b[?2026l", .status = .working },
        .{ .report = .settling, .now_ms = 400, .output = "\x1b[?2026h\x1b[2J\x1b[1;1HThe quote is Working (2s, esc to interrupt).\r\n\xe2\x94\x80 Worked for 2s\r\n\r\n\xe2\x80\xba a drafted follow-up\x1b[4;3H\x1b[?2026l", .status = .done, .sound = true },
        .{ .report = null, .now_ms = 500, .output = "\x1b[4;3H", .status = .done },
    };

    for (cases) |case| {
        capture = .{};
        if (case.report) |state| {
            _ = fixture.agents.observeReport(.{ .identity = identity, .state = state, .observed_at_ms = case.now_ms });
        }

        fixture.pane.queueHistoryOutput(.{ .bytes = case.output, .shell_foreground = false, .clock = .{ .real_ms = case.now_ms + 1, .awake_ns = @intCast(case.now_ms * 1_000_000) } });
        try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
        var stats: history.observer.Stats = .{};
        fixture.pane.processHistoryObservation(.{ .size = size, .provider = .codex }, &stats);
        try coordinator.handle(.{ .pane = fixture.pane.key(), .stats = stats, .process_probe = .{ .cache = processCache(.codex, process_id, "Codex") } });
        try std.testing.expectEqual(case.status, fixture.agents.projectedStatus(identity.key).?);
        try std.testing.expectEqual(case.sound, capture.sound != null);
    }
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
    try std.testing.expectEqual(schema.AgentSound.ready, soundForTransition(.working, .done).?);
    try std.testing.expectEqual(schema.AgentSound.needs_input, soundForTransition(.working, .blocked).?);
    try std.testing.expect(soundForTransition(null, .ready) == null);
    try std.testing.expect(soundForTransition(.ready, .ready) == null);
    try std.testing.expect(soundForTransition(.blocked, .ready) == null);
    try std.testing.expect(soundForTransition(.working, .failed) == null);
}
