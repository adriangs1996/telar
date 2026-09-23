//! Agent and terminal observation contracts through Runtime.update.

const core = @import("telar-core");
const std = @import("std");
const pane_mod = @import("../../pane/pane_namespace.zig");
const CacheType = @import("../../process/Cache.zig");
const Pane = @import("../../pane/Pane.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const agent_identity = @import("../agent_identity.zig");
const StatsType = @import("../../history/Stats.zig");
const TrackerType = @import("../../agent/Tracker.zig");
const sound_module = @import("../../agent/sound.zig");
const ResumeSession = @import("../../agent/ResumeSession.zig");
const SessionReference = @import("../../agent/SessionReference.zig");

const EventFixture = @import("EventFixture.zig");

fn queueFollowUp(fixture: *EventFixture) void {
    fixture.pane.queueHistoryOutput(.{ .bytes = "follow-up", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
}

fn processCache(provider: core.AgentProvider, process_id: u32, executable: []const u8) CacheType {
    var cache = CacheType.init(executable);
    cache.process_group_id = process_id;
    cache.provider = provider;
    return cache;
}

fn nonShellProcessId(pane: *const Pane) u32 {
    const shell = std.math.cast(u32, pane.session.processId()) orelse 1;
    return if (shell == std.math.maxInt(u32)) shell - 1 else shell + 1;
}

const ObservationExpectedMetrics = struct {
    inspections: u64 = 0,
    misses: u64 = 0,
    input_bytes: u64 = 0,
    captured: u64 = 0,
    dropped: u64 = 0,
    failures: u64 = 0,
    resets: u64 = 0,
};

fn expectMetrics(metrics: *const RuntimeMetrics, expected: ObservationExpectedMetrics) !void {
    const actual = if (comptime core.enabled) expected else ObservationExpectedMetrics{};
    try std.testing.expectEqual(actual.inspections, metrics.agent_process_inspections);
    try std.testing.expectEqual(actual.misses, metrics.agent_process_misses);
    try std.testing.expectEqual(actual.input_bytes, metrics.history_candidate_input_bytes);
    try std.testing.expectEqual(actual.captured, metrics.history_captured);
    try std.testing.expectEqual(actual.dropped, metrics.history_dropped);
    try std.testing.expectEqual(actual.failures, metrics.history_observation_failures);
    try std.testing.expectEqual(actual.resets, metrics.history_observation_resets);
}

test "known process observation commits pane state agent evidence and metrics" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.history_observer.tracker.updateCwd("/observed");
    try fixture.beginObservation();
    const process_id = nonShellProcessId(fixture.pane);
    const foreground_revision = fixture.pane.foreground_revision;

    try fixture.observed(.{
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

    try std.testing.expectEqualStrings("/observed", fixture.pane.cwd.slice());
    try std.testing.expectEqual(foreground_revision + 1, fixture.pane.foreground_revision);
    try std.testing.expectEqualStrings("Claude Code", fixture.pane.agent_process_cache.name());
    try std.testing.expectEqual(core.AgentStatus.ready, fixture.agents.projectedStatus(fixture.pane.key()).?);
    try expectMetrics(fixture.metrics, .{
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
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.foreground_revision = std.math.maxInt(u64);
    try fixture.beginObservation();

    try fixture.observed(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.unknown, nonShellProcessId(fixture.pane), "different"),
        },
    });

    try std.testing.expectEqual(@as(u64, 1), fixture.pane.foreground_revision);
}

test "shell foreground removes the agent and ignores screen readiness" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    try std.testing.expect(fixture.agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = process_id,
        .observed_at_ms = 1,
    }));
    const shell_id = std.math.cast(u32, fixture.pane.session.processId()).?;

    try fixture.observed(.{
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

    try std.testing.expect(fixture.agents.projectedStatus(identity.key) == null);
    try std.testing.expect(fixture.sound() == null);
    try expectMetrics(fixture.metrics, .{ .inspections = 1, .misses = 1 });
}

test "shell startup observations preserve a queued resume until the agent starts" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
    const key = fixture.pane.key();
    const session = try ResumeSession.init(.claude, try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0));
    try std.testing.expect(fixture.agents.restoreSession(key, session));
    const shell_id = std.math.cast(u32, fixture.pane.session.processId()).?;

    try fixture.observed(.{
        .pane = key,
        .stats = .{},
        .process_probe = .{ .cache = processCache(.unknown, shell_id, "sh"), .changed = true },
    });
    try std.testing.expect(fixture.agents.awaitingResume(key));
    try std.testing.expect(fixture.agents.resumeSession(key).?.eql(session));
    try std.testing.expect(fixture.agents.projectedStatus(key) == null);

    for ([_]CacheType{
        processCache(.unknown, nonShellProcessId(fixture.pane), "git"),
        processCache(.unknown, shell_id, "sh"),
    }) |cache| {
        queueFollowUp(&fixture);
        try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
        fixture.request.clearResponses();
        try fixture.observed(.{
            .pane = key,
            .stats = .{},
            .process_probe = .{ .cache = cache, .changed = true },
        });
        try std.testing.expect(fixture.agents.awaitingResume(key));
        try std.testing.expect(fixture.agents.resumeSession(key).?.eql(session));
        try std.testing.expect(fixture.agents.projectedStatus(key) == null);
    }

    queueFollowUp(&fixture);
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
    fixture.request.clearResponses();
    try fixture.observed(.{
        .pane = key,
        .stats = .{},
        .process_probe = .{ .cache = processCache(.claude, nonShellProcessId(fixture.pane), "Claude Code"), .changed = true },
    });
    try std.testing.expect(!fixture.agents.awaitingResume(key));
    try std.testing.expect(fixture.agents.resumeSession(key).?.eql(session));

    queueFollowUp(&fixture);
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
    fixture.request.clearResponses();
    try fixture.observed(.{
        .pane = key,
        .stats = .{},
        .process_probe = .{ .cache = processCache(.unknown, shell_id, "sh"), .changed = true },
    });
    try std.testing.expect(fixture.agents.resumeSession(key) == null);
    try std.testing.expect(fixture.agents.projectedStatus(key) == null);
}

test "an unknown non-shell process clears previous process evidence" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
    const process_id = nonShellProcessId(fixture.pane);

    try fixture.observed(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.claude, process_id, "Claude Code"),
            .changed = true,
        },
    });
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) != null);

    fixture.request.clearResponses();
    fixture.pane.queueHistoryOutput(.{ .bytes = "next", .shell_foreground = false, .clock = pane_mod.historyClock(std.testing.io) });
    try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
    const unknown_id = if (process_id == std.math.maxInt(u32)) process_id - 1 else process_id + 1;
    try fixture.observed(.{
        .pane = fixture.pane.key(),
        .stats = .{},
        .process_probe = .{
            .cache = processCache(.unknown, unknown_id, "other"),
            .changed = true,
        },
    });

    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) == null);
}

test "working to ready screen evidence publishes one generation-safe sound" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
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

    try fixture.observed(.{
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

    try std.testing.expectEqual(core.AgentStatus.done, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expectEqualDeep(core.AgentSoundNotification{
        .pane_id = identity.key.id,
        .pane_generation = identity.key.generation,
        .sound = .ready,
    }, fixture.sound().?);
}

test "a delayed screen completion cannot settle a newer Codex Stop or publish a sound" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    _ = fixture.agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = process_id, .observed_at_ms = 100 });
    _ = fixture.agents.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 300 });

    try fixture.observed(.{
        .pane = fixture.pane.key(),
        .stats = .{ .agent_observation = .{
            .observed_at_ms = 200,
            .signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true },
        } },
        .process_probe = .{ .cache = processCache(.codex, process_id, "Codex") },
    });

    try std.testing.expectEqual(core.AgentStatus.working, fixture.agents.projectedStatus(identity.key).?);
    try std.testing.expect(fixture.sound() == null);
}

test "Codex PTY frames and continuing Stop hooks publish exactly one final completion sound" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const size: core.TerminalSize = .{ .cols = 100, .rows = 16 };
    fixture.pane.history_observer.queueResize(size);
    const identity = agent_identity.fromPane(fixture.pane);
    const process_id = nonShellProcessId(fixture.pane);
    _ = fixture.agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = process_id, .observed_at_ms = 50 });

    const cases = [_]struct {
        report: ?core.AgentReportState,
        now_ms: i64,
        output: []const u8,
        status: core.AgentStatus,
        sound: bool = false,
    }{
        .{ .report = .working, .now_ms = 100, .output = "\x1b[1;1HWorking (1s)\x1b[4;1H\xe2\x80\xba Ask Codex to do anything\x1b[4;3H", .status = .working },
        .{ .report = .settling, .now_ms = 200, .output = "\x1b[?2026h\x1b[1;1H\x1b[2K\x1b[4;3H", .status = .working },
        .{ .report = .working, .now_ms = 300, .output = "\x1b[1;1HWorking (2s)\x1b[4;3H\x1b[?2026l", .status = .working },
        .{ .report = .settling, .now_ms = 400, .output = "\x1b[?2026h\x1b[2J\x1b[1;1HThe quote is Working (2s, esc to interrupt).\r\n\xe2\x94\x80 Worked for 2s\r\n\r\n\xe2\x80\xba a drafted follow-up\x1b[4;3H\x1b[?2026l", .status = .done, .sound = true },
        .{ .report = null, .now_ms = 500, .output = "\x1b[4;3H", .status = .done },
    };

    for (cases) |case| {
        fixture.request.clearResponses();
        if (case.report) |state| {
            _ = fixture.agents.observeReport(.{ .identity = identity, .state = state, .observed_at_ms = case.now_ms });
        }

        fixture.pane.queueHistoryOutput(.{ .bytes = case.output, .shell_foreground = false, .clock = .{ .real_ms = case.now_ms + 1, .awake_ns = @intCast(case.now_ms * 1_000_000) } });
        try std.testing.expect(fixture.pane.beginHistoryObservation() != null);
        var stats: StatsType = .{};
        fixture.pane.processHistoryObservation(.{ .size = size, .provider = .codex }, &stats);
        try fixture.observed(.{ .pane = fixture.pane.key(), .stats = stats, .process_probe = .{ .cache = processCache(.codex, process_id, "Codex") } });
        try std.testing.expectEqual(case.status, fixture.agents.projectedStatus(identity.key).?);
        try std.testing.expectEqual(case.sound, fixture.sound() != null);
    }
}

test "sounds are restricted to working-to-ready and working-to-blocked transitions" {
    try std.testing.expectEqual(core.AgentSound.ready, sound_module.soundForTransition(.working, .ready).?);
    try std.testing.expectEqual(core.AgentSound.ready, sound_module.soundForTransition(.working, .done).?);
    try std.testing.expectEqual(core.AgentSound.needs_input, sound_module.soundForTransition(.working, .blocked).?);
    try std.testing.expect(sound_module.soundForTransition(null, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.ready, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.blocked, .ready) == null);
    try std.testing.expect(sound_module.soundForTransition(.working, .failed) == null);
}

test "a pane-root agent keeps its resumed session and receives screen observations" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.beginObservation();
    const key = fixture.pane.key();
    const session = try ResumeSession.init(.codex, try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0));
    try std.testing.expect(fixture.agents.restoreSession(key, session));
    const root_id = std.math.cast(u32, fixture.pane.session.processId()).?;

    try fixture.observed(.{
        .pane = key,
        .stats = .{ .agent_observation = .{
            .observed_at_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds() + 1000,
            .signal = .{ .provider = .codex, .status = .working, .confidence = 100, .identity_confirmed = true },
        } },
        .process_probe = .{ .cache = processCache(.codex, root_id, "Codex"), .changed = true, .inspected = true },
    });

    try std.testing.expect(!fixture.agents.awaitingResume(key));
    try std.testing.expect(fixture.agents.resumeSession(key).?.eql(session));
    try std.testing.expectEqual(core.AgentProvider.codex, fixture.agents.projectedProvider(key));
    try std.testing.expectEqual(core.AgentStatus.working, fixture.agents.projectedStatus(key).?);
}
