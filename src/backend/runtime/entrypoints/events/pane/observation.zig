//! Coordination for asynchronous pane history and agent observation.

const GenericObservationRuntimePort = @import("GenericObservationRuntimePort.zig").Type;
const ObservationCapture = @import("ObservationCapture.zig");
const GenericObservationCoordinator = @import("GenericObservationCoordinator.zig").Type;
const PaneFixtureType = @import("../../../tests/PaneFixture.zig");
const PaneStore = @import("../../../../pane/PaneStore.zig");
const std = @import("std");
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const CacheType = @import("../../../../process/Cache.zig");
const Pane = @import("../../../../pane/Pane.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const ObservationExpectedMetrics = @import("ObservationExpectedMetrics.zig");
const enabled_module = @import("telar-core").enabled;
const AgentStatusType = @import("telar-core").AgentStatus;
const agent_identity = @import("../../../application/coordinators/agent_identity.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
const TerminalSizeType = @import("telar-core").TerminalSize;
const AgentReportStateType = @import("telar-core").AgentReportState;
const StatsType = @import("../../../../history/Stats.zig");
const TrackerType = @import("../../../../agent/Tracker.zig");
const AgentSoundType = @import("telar-core").AgentSound;
const sound_module = @import("../../../../agent/sound.zig");

pub const Step = enum {
    sound,
    description,
    observation,
    collect,
    pump_clients,
};

const test_port: GenericObservationRuntimePort(ObservationCapture) = .{
    .start = ObservationCapture.start,
    .publish_sound = ObservationCapture.publishSound,
    .schedule_description = ObservationCapture.scheduleDescription,
    .collect = ObservationCapture.collect,
    .pump_clients = ObservationCapture.pumpClients,
};

const TestCoordinator = GenericObservationCoordinator(ObservationCapture, test_port);

fn testCoordinator(capture: *ObservationCapture, fixture: *PaneFixtureType, panes: *PaneStore) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .agents = &fixture.agents,
        .metrics = &fixture.metrics,
    });
}

fn beginFixtureObservation(fixture: *PaneFixtureType, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    fixture.pane.queueHistoryOutput(.{ .bytes = "observed", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
}

fn queueFollowUp(fixture: *PaneFixtureType) void {
    fixture.pane.queueHistoryOutput(.{ .bytes = "follow-up", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
}

fn processCache(provider: AgentProviderType, process_id: u32, executable: []const u8) CacheType {
    var cache = CacheType.init(executable);
    cache.process_group_id = process_id;
    cache.provider = provider;
    return cache;
}

fn nonShellProcessId(pane: *const Pane) u32 {
    const shell = std.math.cast(u32, pane.session.processId()) orelse 1;
    return if (shell == std.math.maxInt(u32)) shell - 1 else shell + 1;
}

fn expectSteps(capture: *const ObservationCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectMetrics(metrics: *const RuntimeMetrics, expected: ObservationExpectedMetrics) !void {
    const actual = if (comptime enabled_module) expected else ObservationExpectedMetrics{};
    try std.testing.expectEqual(actual.inspections, metrics.agent_process_inspections);
    try std.testing.expectEqual(actual.misses, metrics.agent_process_misses);
    try std.testing.expectEqual(actual.input_bytes, metrics.history_candidate_input_bytes);
    try std.testing.expectEqual(actual.captured, metrics.history_captured);
    try std.testing.expectEqual(actual.dropped, metrics.history_dropped);
    try std.testing.expectEqual(actual.failures, metrics.history_observation_failures);
    try std.testing.expectEqual(actual.resets, metrics.history_observation_resets);
}

test "known process observation commits pane state agent evidence and metrics" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.history_observer.tracker.updateCwd("/observed");
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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
    try std.testing.expectEqual(AgentStatusType.ready, fixture.agents.projectedStatus(fixture.pane.key()).?);
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.foreground_revision = std.math.maxInt(u64);
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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
    try std.testing.expectEqual(AgentStatusType.done, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expectEqualDeep(AgentSoundNotificationType{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = .ready,
    }, capture.sound.?);
}

test "a delayed screen completion cannot settle a newer Codex Stop or publish a sound" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    var capture: ObservationCapture = .{};
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

    try std.testing.expectEqual(AgentStatusType.working, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expect(capture.sound == null);
}

test "Codex PTY frames and continuing Stop hooks publish exactly one final completion sound" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    const size: TerminalSizeType = .{ .cols = 100, .rows = 16 };
    fixture.pane.history_observer.queueResize(size);
    var panes: PaneStore = .{};
    try panes.insert(fixture.pane);
    var capture: ObservationCapture = .{};
    var coordinator = testCoordinator(&capture, &fixture, &panes);
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    _ = fixture.agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = process_id, .observed_at_ms = 50 });

    const cases = [_]struct {
        report: ?AgentReportStateType,
        now_ms: i64,
        output: []const u8,
        status: AgentStatusType,
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
        var stats: StatsType = .{};
        fixture.pane.processHistoryObservation(.{ .size = size, .provider = .codex }, &stats);
        try coordinator.handle(.{ .pane = fixture.pane.key(), .stats = stats, .process_probe = .{ .cache = processCache(.codex, process_id, "Codex") } });
        try std.testing.expectEqual(case.status, fixture.agents.projectedStatus(identity.key).?);
        try std.testing.expectEqual(case.sound, capture.sound != null);
    }
}

test "pending history is rearmed after description scheduling" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: ObservationCapture = .{};
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureObservation(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: ObservationCapture = .{ .start_failure = true };
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
    var agents: TrackerType = .{};
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: ObservationCapture = .{};
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
    try std.testing.expectEqual(AgentSoundType.ready, sound_module.soundForTransition(.working, .ready).?);
    try std.testing.expectEqual(AgentSoundType.ready, sound_module.soundForTransition(.working, .done).?);
    try std.testing.expectEqual(AgentSoundType.needs_input, sound_module.soundForTransition(.working, .blocked).?);
    try std.testing.expect(sound_module.soundForTransition(null, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.ready, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.blocked, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.working, .failed) == null);
}
