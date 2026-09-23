//! Runtime-owned coordinator for agent observations and projections.
//!
//! The tracker resolves observations to one pane generation, delegates every
//! state transition to that aggregate, and publishes revisioned snapshots.

const core = @import("telar-core");
const Identity = @import("Identity.zig");
const types = @import("types.zig");
const TestProxyObservation = @import("TestProxyObservation.zig");
const TestReadyPrompt = @import("TestReadyPrompt.zig");
const Tracker = @import("Tracker.zig");
const std = @import("std");
const Agent = @import("Agent.zig");
const Result = @import("Result.zig");
const description = @import("description.zig");
const ProxyExchange = @import("ProxyExchange.zig");
const SessionReference = @import("SessionReference.zig");
const SessionTitle = @import("SessionTitle.zig");
const SessionFile = @import("SessionFile.zig");
const Completion = @import("Completion.zig");

pub const AcknowledgeResult = enum {
    unknown_agent,
    unchanged,
    acknowledged,
};

fn testIdentity() !Identity {
    return .{
        .key = .{ .id = try core.pane(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
}

fn testIdentityAt(id: u32, generation: u64) !Identity {
    return .{
        .key = .{ .id = try core.pane(id), .generation = generation },
        .process_id = id,
        .session_id = .{@as(u8, @intCast(id))} ** 16,
    };
}

fn testProxy(dialect: types.ApiDialect, phase: types.ProxyPhase, observed_at_ms: i64) TestProxyObservation {
    return .{ .dialect = dialect, .phase = phase, .observed_at_ms = observed_at_ms };
}

fn testReadyPrompt(provider: core.AgentProvider, observed_at_ms: i64) TestReadyPrompt {
    return .{ .provider = provider, .observed_at_ms = observed_at_ms };
}

fn observeTestProxy(tracker: *Tracker, identity: Identity, observation: TestProxyObservation) bool {
    return tracker.observeProxy(.{
        .identity = identity,
        .dialect = observation.dialect,
        .phase = observation.phase,
        .observed_at_ms = observation.observed_at_ms,
        .exchange = .{
            .protocol = .h2,
            .connection_id = 1,
            .stream_id = 1,
        },
    });
}

fn observeTestReadyPrompt(tracker: *Tracker, identity: Identity, prompt: TestReadyPrompt) bool {
    return tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = prompt.provider,
            .status = .ready,
            .confidence = 96,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = prompt.observed_at_ms,
    });
}

test "an agent without evidence does not consume a projection sequence" {
    var tracker: Tracker = .{ .sequence = 41 };
    var agent = Agent.init(try testIdentity());

    try std.testing.expect(!tracker.reproject(&agent, 100));
    try std.testing.expectEqual(@as(u64, 41), tracker.sequence);
    try std.testing.expectEqual(@as(u64, 1), tracker.revision);
}

test "tracker rejects every observation that would exceed repository capacity" {
    var tracker: Tracker = .{};

    for (0..core.max_agent_snapshot_entries) |index| {
        const identity = try testIdentityAt(@intCast(index + 1), 1);
        try std.testing.expect(tracker.observeProcess(.{
            .identity = identity,
            .provider = .claude,
            .process_id = identity.process_id,
            .observed_at_ms = 100,
        }));
    }

    const overflow = try testIdentityAt(@intCast(core.max_agent_snapshot_entries + 1), 1);
    try std.testing.expect(!tracker.observeProcess(.{
        .identity = overflow,
        .provider = .claude,
        .process_id = overflow.process_id,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = overflow,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 96,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!observeTestProxy(&tracker, overflow, testProxy(.anthropic_messages, .request_started, 200)));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(core.max_agent_snapshot_entries, tracker.snapshot(&entries, 0).len);
}

test "only a confirmed prompt settles model work" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 100)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .response_finished, 200)));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 300,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, snapshot[0].source);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 400)));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "explicit Codex prompt settles working without repetition" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 100)));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "Codex Stop stays working until a newer input prompt confirms completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 42,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeReport(.{
        .identity = identity,
        .state = .working,
        .observed_at_ms = 200,
    }));

    try std.testing.expect(tracker.observeReport(.{
        .identity = identity,
        .state = .settling,
        .observed_at_ms = 300,
    }));
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 400,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "Codex active tool reports cannot be settled by a repainted composer" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true },
        .observed_at_ms = 201,
    });
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
}

test "a continuing Codex hook cancels pending settlement and only the final Stop can complete" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 300 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 400 });

    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 401 });
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 500 });

    for ([_]i64{ 300, 499, 500 }) |stale| {
        _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = stale });
        try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    }

    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 501 });
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);
    _ = tracker.acknowledge(identity.key, 502);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 503 });
    try std.testing.expectEqual(core.AgentStatus.ready, tracker.projectedStatus(identity.key).?);
}

test "Codex evidence expiration cannot turn an old prompt into a completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 101 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 150 });
    _ = tracker.expire(200 + types.working_expiry_ms);
    try std.testing.expectEqual(core.AgentStatus.unknown, tracker.projectedStatus(identity.key).?);
}

test "new Codex activity supersedes an older SessionStart or Interrupt ready report" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 200 });
    _ = tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .codex, .status = .working, .confidence = 94 },
        .observed_at_ms = 201,
    });
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
}

test "a Codex model response never completes the agent turn without a new composer" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 101 });
    _ = observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 200));
    _ = observeTestProxy(&tracker, identity, testProxy(.openai_responses, .provider_turn_completed, 300));
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 301 });
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);
}

test "Codex settlement orders events within one millisecond by the monotonic clock" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 200, .observed_at_ns = 2_000_000 });
    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 1_999_999 });
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 2_000_001 });
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);
}

test "an older Codex prompt cannot overrule current lifecycle work" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 42,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeReport(.{
        .identity = identity,
        .state = .working,
        .observed_at_ms = 300,
    }));

    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
            .ready_confirmed = true,
        },
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
}

test "agent branding alone does not settle working" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 100)));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, snapshot[0].source);
}

test "screen text cannot register an agent without independent evidence" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        .observed_at_ms = 100,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

test "foreground process establishes agent identity without screen branding" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);

    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .working, .confidence = 78 },
        .observed_at_ms = 200,
    }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);
}

test "first working turn starts one generated session title" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqualStrings(core.generic_placeholder, snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(tracker.observeInput(identity.key, "improve the sidebar\r"));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 150)));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 200)));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentTitleState.pending, snapshot[0].title_state);

    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("improve the sidebar", job.querySlice());
    var result: Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Improve agent sidebar".len,
    };
    @memcpy(result.title[0..result.title_len], "Improve agent sidebar");
    const finished = tracker.finishDescription(&result).?;
    @memset(result.title[0..result.title_len], 'x');
    try std.testing.expectEqualDeep(job.pane, finished.pane);
    try std.testing.expectEqualSlices(u8, &job.session_id, &finished.session_id);
    try std.testing.expectEqualStrings("Improve agent sidebar", finished.titleSlice());
    try std.testing.expectEqual(core.AgentTitleSource.generated, finished.source);
    try std.testing.expectEqual(core.AgentTitleState.ready, finished.state);
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqualStrings("Improve agent sidebar", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(core.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expect(tracker.nextDescriptionJob() == null);
}

test "submitted managed prompt queues once even when working is coalesced into ready" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeManaged(identity, .{ .status = .ready, .observed_at_ms = 100 }));
    const before = tracker.revision;
    try std.testing.expect(tracker.observeSubmittedPrompt(identity, "Fix the sidebar\nKeep UTF-8 界 intact"));
    try std.testing.expect(tracker.revision > before);
    const admitted = tracker.revision;
    try std.testing.expect(!tracker.observeSubmittedPrompt(identity, "A later turn must not replace the first"));
    try std.testing.expectEqual(admitted, tracker.revision);

    _ = tracker.observeManaged(identity, .{ .status = .ready, .observed_at_ms = 200 });
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(core.AgentTitleState.pending, tracker.snapshot(&entries, 200)[0].title_state);
    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("Fix the sidebar Keep UTF-8 界 intact", job.querySlice());
    try std.testing.expect(tracker.nextDescriptionJob() == null);
    var result: Result = .{ .pane = job.pane, .session_id = job.session_id, .status = .success, .title_len = "Fix sidebar".len };
    @memcpy(result.title[0..result.title_len], "Fix sidebar");
    _ = tracker.finishDescription(&result).?;
    try std.testing.expectEqualStrings("Fix sidebar", tracker.snapshot(&entries, 200)[0].session_title);
    try std.testing.expect(!tracker.observeSubmittedPrompt(identity, "Another request"));
    try std.testing.expect(tracker.nextDescriptionJob() == null);
}

test "submitted managed prompt preserves ready manual and reported titles" {
    for ([_]bool{ false, true }) |manual| {
        var tracker: Tracker = .{};
        const identity = try testIdentity();
        _ = tracker.observeManaged(identity, .{ .status = .ready, .observed_at_ms = 100 });
        if (manual) {
            _ = try tracker.setManualTitle(identity.key, "Existing title");
        } else {
            _ = try tracker.reportTitle(identity, "Existing title");
        }

        const before = tracker.revision;
        try std.testing.expect(!tracker.observeSubmittedPrompt(identity, "Do not generate over this title"));
        try std.testing.expectEqual(before, tracker.revision);
        try std.testing.expect(tracker.nextDescriptionJob() == null);
    }
}

test "submitted managed prompt shares the bounded description queue" {
    var tracker: Tracker = .{};
    for (0..description.max_pending_jobs + 1) |index| {
        const identity = try testIdentityAt(@intCast(index + 1), 1);
        _ = tracker.observeManaged(identity, .{ .status = .ready, .observed_at_ms = 100 });
        try std.testing.expect(tracker.observeSubmittedPrompt(identity, "First accepted prompt"));
        try std.testing.expect(!tracker.observeSubmittedPrompt(identity, "Never retry title generation"));
    }

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var pending: usize = 0;
    var failed: usize = 0;
    for (tracker.snapshot(&entries, 100)) |entry| {
        switch (entry.title_state) {
            .pending => pending += 1,
            .failed => failed += 1,
            else => return error.UnexpectedTitleState,
        }
    }

    try std.testing.expectEqual(description.max_pending_jobs, pending);
    try std.testing.expectEqual(@as(usize, 1), failed);
}

test "manual title wins over a late generated result" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeInput(identity.key, "fix tests\r"));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 200)));
    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));

    var result: Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Generated title".len,
    };
    @memcpy(result.title[0..result.title_len], "Generated title");
    try std.testing.expect(tracker.finishDescription(&result) == null);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqualStrings("Release audit", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.manual, snapshot[0].title_source);
}

test "description backpressure fails the ninth queued request without retry" {
    var tracker: Tracker = .{};
    for (0..description.max_pending_jobs + 1) |index| {
        const raw: u64 = @intCast(index + 1);
        const identity: Identity = .{
            .key = .{ .id = try core.pane(raw), .generation = raw },
            .process_id = @intCast(raw),
            .session_id = @splat(@intCast(raw)),
        };
        try std.testing.expect(tracker.observeProcess(.{
            .identity = identity,
            .provider = .codex,
            .process_id = @intCast(raw),
            .observed_at_ms = 100,
        }));
        try std.testing.expect(tracker.observeInput(identity.key, "do work\r"));
        try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 200)));
    }
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    var pending: usize = 0;
    var failed: usize = 0;
    for (snapshot) |entry| switch (entry.title_state) {
        .pending => pending += 1,
        .failed => failed += 1,
        else => {},
    };
    try std.testing.expectEqual(description.max_pending_jobs, pending);
    try std.testing.expectEqual(@as(usize, 1), failed);
}

test "process identity rejects contradictory screen branding" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = true,
        },
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
}

test "foreground process exit removes all evidence for that session" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(tracker.clearProcess(identity.key));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 0).len);
}

test "new foreground process replaces prior session evidence" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = 85,
        .observed_at_ms = 300,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentProvider.codex, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.unknown, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(core.AgentAuthority.active, snapshot[0].authority);
    try std.testing.expectEqual(@as(u32, 85), snapshot[0].process_id);
}

test "confirmed Claude prompt refreshes branded identity" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 100,
    }));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 200)));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "network work resumes a visibly blocked agent" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(tracker.observeProcess(.{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 100,
    }));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 200)));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentAuthority.resumed, snapshot[0].authority);
}

test "new network work supersedes an older ready prompt" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .response_finished, 100)));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 200)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 300)));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, snapshot[0].source);
}

test "unmatched proxy responses cannot create agent state" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_activity,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_failed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 0).len);
}

test "a contradictory provider cannot complete another agent's exchange" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    });
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
}

test "transport completion without provider turn completion remains working" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, snapshot[0].source);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "provider turn completion projects ready and ignores later transport completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = exchange,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.proxy_tls, snapshot[0].source);
    try std.testing.expectEqual(@as(u8, 99), snapshot[0].confidence);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);

    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "all concurrent model exchanges must complete before ready" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };

    for ([_]ProxyExchange{ first, second }, 0..) |exchange, index| {
        try std.testing.expect(tracker.observeProxy(.{
            .identity = identity,
            .dialect = .anthropic_messages,
            .phase = .request_started,
            .exchange = exchange,
            .observed_at_ms = @intCast(100 + index),
        }));
    }

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = first,
        .observed_at_ms = 200,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
}

test "new model work supersedes a completed response" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const completed: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const next: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };

    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = completed,
        .observed_at_ms = 100,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = completed,
        .observed_at_ms = 200,
    });
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = next,
        .observed_at_ms = 300,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 300), snapshot[0].observed_at_ms);
}

test "expired agent evidence is removed" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .response_finished, 100)));
    try std.testing.expect(tracker.expire(100 + types.settled_expiry_ms));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 0).len);
}

test "expiration removes every adjacent stale aggregate" {
    var tracker: Tracker = .{};
    const first = try testIdentityAt(1, 1);
    const second = try testIdentityAt(2, 1);

    try std.testing.expect(observeTestProxy(&tracker, first, testProxy(.openai_responses, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, first, testProxy(.openai_responses, .response_finished, 100)));
    try std.testing.expect(observeTestProxy(&tracker, second, testProxy(.openai_responses, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, second, testProxy(.openai_responses, .response_finished, 100)));
    try std.testing.expect(tracker.expire(100 + types.settled_expiry_ms));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 0).len);
}

test "a bare shell prompt is not Claude identity" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .ready, .confidence = 72 },
        .observed_at_ms = 100,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 0).len);
}

test "completed HTTP2 streams do not settle the agent turn" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    });

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 300,
    });
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 400)));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
}

test "sequential model requests stay working until a confirmed prompt" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 9, .stream_id = 3 };
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = first,
        .observed_at_ms = 200,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 400,
    }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 500)));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "HTTP2 connection failure settles all of its active streams" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const first: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 1 };
    const second: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 3 };
    const connection: ProxyExchange = .{ .protocol = .h2, .connection_id = 11, .stream_id = 0 };
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = first,
        .observed_at_ms = 100,
    });
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = second,
        .observed_at_ms = 101,
    });
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_failed,
        .exchange = connection,
        .observed_at_ms = 201,
    }));
}

test "session references attach to the exact generation and replace only on change" {
    var tracker: Tracker = .{};
    const identity: Identity = .{
        .key = .{ .id = try core.pane(3), .generation = 2 },
        .process_id = 40,
        .session_id = .{1} ** 16,
    };
    const first = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 10);

    try std.testing.expect(tracker.observeSessionReference(identity, first));
    try std.testing.expect(!tracker.observeSessionReference(identity, first));
    try std.testing.expectEqualStrings(first.slice(), tracker.sessionReference(identity.key).?.slice());
    try std.testing.expect(tracker.sessionReference(.{ .id = identity.key.id, .generation = 3 }) == null);

    const second = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 20);
    try std.testing.expect(tracker.observeSessionReference(identity, second));
    try std.testing.expectError(error.InvalidSessionReference, SessionReference.init("-rf", 0));
    try std.testing.expectError(error.InvalidSessionReference, SessionReference.init("a b", 0));
}

test "a restored title waits for the resumed agent and skips title generation" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);

    try std.testing.expect(tracker.restoreTitle(identity.key, title));
    try std.testing.expect(tracker.durableTitle(identity.key) == null);
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 100 }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(core.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", tracker.durableTitle(identity.key).?.slice());

    try std.testing.expect(!tracker.observeInput(identity.key, "fix the tests\r"));
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 }));
    try std.testing.expect(tracker.nextDescriptionJob() == null);
}

test "a pending resume survives observation ticks without inventing an active agent" {
    const ResumeSession = @import("ResumeSession.zig");
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0);
    const session = try ResumeSession.init(.claude, reference);
    const title = try SessionTitle.init("Keep resume metadata", .manual);
    try std.testing.expect(tracker.restoreSession(identity.key, session));
    try std.testing.expect(tracker.restoreTitle(identity.key, title));

    _ = tracker.expire(10_000);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries, 10_000).len);
    try std.testing.expect(tracker.hasRestoredSession(session));
    try std.testing.expect(tracker.resumeSession(identity.key).?.eql(session));
    try std.testing.expectEqualStrings(title.slice(), tracker.checkpointTitle(identity.key).?.slice());
    try std.testing.expect(tracker.resumeSession(.{ .id = identity.key.id, .generation = identity.key.generation + 1 }) == null);

    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 11_000 }));
    try std.testing.expect(!tracker.hasRestoredSession(session));
    try std.testing.expect(tracker.resumeSession(identity.key).?.eql(session));
    try std.testing.expectEqualStrings(title.slice(), tracker.durableTitle(identity.key).?.slice());
    try std.testing.expect(tracker.remove(identity.key));
    try std.testing.expect(tracker.resumeSession(identity.key) == null);
}

test "a pending resume is discarded for another provider or a different reported session" {
    const ResumeSession = @import("ResumeSession.zig");
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0);
    const session = try ResumeSession.init(.claude, reference);
    const title = try SessionTitle.init("Old session", .manual);

    var other_provider: Tracker = .{};
    try std.testing.expect(other_provider.restoreSession(identity.key, session));
    try std.testing.expect(other_provider.restoreTitle(identity.key, title));
    try std.testing.expect(other_provider.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 99, .session = reference }));
    try std.testing.expect(other_provider.durableTitle(identity.key) == null);
    try std.testing.expect(other_provider.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 43, .observed_at_ms = 100 }));
    try std.testing.expect(other_provider.resumeSession(identity.key) == null);
    try std.testing.expect(other_provider.durableTitle(identity.key) == null);

    var other_session: Tracker = .{};
    try std.testing.expect(other_session.restoreSession(identity.key, session));
    try std.testing.expect(other_session.restoreTitle(identity.key, title));
    try std.testing.expect(other_session.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 99 }));
    try std.testing.expect(other_session.durableTitle(identity.key) == null);
    const replacement = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 100);
    try std.testing.expect(other_session.observeSessionReference(identity, replacement));
    try std.testing.expect(!other_session.hasRestoredSession(session));
    try std.testing.expect(other_session.durableTitle(identity.key) == null);
    try std.testing.expect(other_session.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 101 }));
    try std.testing.expectEqualStrings(replacement.slice(), other_session.resumeSession(identity.key).?.reference.slice());
}

test "a proxy provider guess cannot authorize resume for a reported session" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100);
    try std.testing.expect(tracker.observeSessionReference(identity, reference));
    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .request_started,
        .exchange = .{ .protocol = .http11, .connection_id = 1, .stream_id = 0 },
        .observed_at_ms = 100,
    }));
    try std.testing.expectEqual(core.AgentProvider.claude, tracker.projectedProvider(identity.key));
    try std.testing.expect(tracker.resumeSession(identity.key) == null);
}

test "an agent title outranks generated titles, never clears a manual one and is durable" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();

    try std.testing.expect(try tracker.reportTitle(identity, "Fix proxy"));
    try std.testing.expect(!try tracker.reportTitle(identity, "Fix proxy"));
    try std.testing.expectEqual(core.AgentTitleSource.agent, tracker.durableTitle(identity.key).?.source);
    try std.testing.expectEqualStrings("Fix proxy", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expectError(error.InvalidAgentTitle, tracker.reportTitle(identity, "bad\x1btitle"));

    try std.testing.expect(try tracker.reportTitle(identity, ""));
    try std.testing.expect(tracker.durableTitle(identity.key) == null);
    try std.testing.expect(!try tracker.reportTitle(identity, ""));

    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));
    try std.testing.expect(!try tracker.reportTitle(identity, ""));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expect(try tracker.reportTitle(identity, "Fix proxy again"));
    try std.testing.expectEqual(core.AgentTitleSource.agent, tracker.durableTitle(identity.key).?.source);
}

test "a reported session file is watched, probed once at a time and its names become agent titles" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100);
    const file: SessionFile = .{ .kind = .codex_state, .path = "/state_5.sqlite" };

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 100, .session_file = file }));
    try std.testing.expect(tracker.nextSessionFileProbe(2_000, 1_000) == null);
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200, .session = reference, .session_file = file }));

    const first = tracker.nextSessionFileProbe(2_000, 1_000).?;
    try std.testing.expectEqualStrings("/state_5.sqlite", first.pathSlice());
    try std.testing.expectEqual(core.AgentSessionFileKind.codex_state, first.kind);
    try std.testing.expect(first.offset == null);
    try std.testing.expect(tracker.nextSessionFileProbe(9_000, 1_000) == null);

    try std.testing.expect(!tracker.finishSessionFileProbe(.{ .key = identity.key, .offset = 300 }, 2_100));
    try std.testing.expect(tracker.nextSessionFileProbe(2_500, 1_000) == null);
    try std.testing.expectEqual(@as(?u64, 300), tracker.nextSessionFileProbe(3_200, 1_000).?.offset);

    var named: Completion = .{ .key = identity.key, .offset = 420 };
    named.setTitle("Fix proxy");
    try std.testing.expect(tracker.finishSessionFileProbe(named, 3_300));
    try std.testing.expectEqualStrings("Fix proxy", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expectEqual(core.AgentTitleSource.agent, tracker.durableTitle(identity.key).?.source);
    try std.testing.expect(!tracker.finishSessionFileProbe(named, 3_400));

    // The same name read again after a manual rename does not undo it.
    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));
    try std.testing.expect(!tracker.finishSessionFileProbe(named, 3_500));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());

    var cleared: Completion = .{ .key = identity.key, .offset = 420 };
    cleared.setTitle("");
    try std.testing.expect(!tracker.finishSessionFileProbe(cleared, 3_600));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());

    try std.testing.expect(tracker.remove(identity.key));
    try std.testing.expect(tracker.nextSessionFileProbe(9_000, 1_000) == null);
    try std.testing.expectEqual(@as(usize, 0), tracker.watches.count());
}

test "a restored title is dropped with its pane and never reaches another generation" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const title = try SessionTitle.init("Release audit", .manual);

    try std.testing.expect(tracker.restoreTitle(identity.key, title));
    try std.testing.expect(!tracker.remove(identity.key));
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 43, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.durableTitle(identity.key) == null);

    // A pane id holds one generation at a time: the next generation's agent
    // exists only after the previous one is gone, and never inherits its
    // restored title.
    const next_generation: Identity = .{ .key = .{ .id = identity.key.id, .generation = identity.key.generation + 1 }, .process_id = 44, .session_id = .{1} ** 16 };
    try std.testing.expect(tracker.remove(identity.key));
    try std.testing.expect(tracker.restoreTitle(identity.key, title));
    try std.testing.expect(tracker.observeProcess(.{ .identity = next_generation, .provider = .codex, .process_id = 45, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.durableTitle(next_generation.key) == null);

    try std.testing.expect(tracker.remove(next_generation.key));
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 46, .observed_at_ms = 100 }));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());
}

test "lifecycle reports outrank screen and proxy evidence until they expire" {
    var tracker: Tracker = .{};
    const identity: Identity = .{
        .key = .{ .id = try core.pane(5), .generation = 1 },
        .process_id = 40,
        .session_id = .{2} ** 16,
    };
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 41, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(core.AgentStatus.blocked, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 300 }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.lifecycle_report, snapshot[0].source);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 400 }));
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .exited, .observed_at_ms = 500 }));
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 600 }));
    _ = tracker.expire(600 + types.working_expiry_ms + 1);
    snapshot = tracker.snapshot(&entries, 0);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "Pi report renewal keeps a long tool working and loss cannot announce completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .pi, .process_id = 42, .observed_at_ms = 100 });
    try std.testing.expectEqual(core.AgentStatus.unknown, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });

    for (1..11) |tick| {
        const now: i64 = 200 + @as(i64, @intCast(tick)) * 30_000;
        _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = now });
        _ = tracker.expire(now + 29_999);
        try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    }

    _ = tracker.expire(300_200 + types.working_expiry_ms);
    try std.testing.expectEqual(core.AgentStatus.unknown, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 500_000 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 500_001 });
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);
}

test "Pi model completion followed by local tools is not an agent completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .pi, .process_id = 42, .observed_at_ms = 100 });
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 1, .stream_id = 1 };
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .request_started, .exchange = exchange, .observed_at_ms = 200 });
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .provider_turn_completed, .exchange = exchange, .observed_at_ms = 300 });
    try std.testing.expectEqual(core.AgentStatus.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.expire(300 + types.working_expiry_ms);
    try std.testing.expectEqual(core.AgentStatus.unknown, tracker.projectedStatus(identity.key).?);
}

test "a blocked report names its reason and event and the proxy names permission without one" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 }));

    try std.testing.expect(tracker.observeReport(.{
        .identity = identity,
        .state = .blocked,
        .blocked_reason = .question,
        .event = "Which database?",
        .observed_at_ms = 200,
    }));
    var snapshot = tracker.snapshot(&entries, 200);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentBlockedReason.question, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("Which database?", snapshot[0].last_event);

    // A working report replaces the question with the tool call.
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .event = "» Edit src/proxy.zig", .observed_at_ms = 300 }));
    snapshot = tracker.snapshot(&entries, 300);
    try std.testing.expectEqual(core.AgentBlockedReason.none, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("» Edit src/proxy.zig", snapshot[0].last_event);

    // Without a report, a response that closed on a tool request and a
    // visible prompt is a permission prompt.
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .exited, .observed_at_ms = 400 }));
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 1, .stream_id = 1 };
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .anthropic_messages, .phase = .request_started, .exchange = exchange, .observed_at_ms = 500 });
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .anthropic_messages, .phase = .response_finished, .exchange = exchange, .observed_at_ms = 600 });
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 700,
    }));
    snapshot = tracker.snapshot(&entries, 700);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentBlockedReason.permission, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("", snapshot[0].last_event);

    // A blocked screen with no proxy story has no named reason.
    _ = tracker.expire(600 + types.working_expiry_ms + 1);
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 600 + types.working_expiry_ms + 2,
    }));
    snapshot = tracker.snapshot(&entries, 600 + types.working_expiry_ms + 2);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentBlockedReason.other, snapshot[0].blocked_reason);
}

test "the status age follows the last status change and never advances the revision" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 1_000 }));
    try std.testing.expectEqual(@as(u32, 0), tracker.snapshot(&entries, 500)[0].status_age_s);
    try std.testing.expectEqual(@as(u32, 4), tracker.snapshot(&entries, 5_999)[0].status_age_s);

    const revision = tracker.revision;
    try std.testing.expectEqual(@as(u32, 60), tracker.snapshot(&entries, 61_000)[0].status_age_s);
    try std.testing.expectEqual(revision, tracker.revision);

    // Renewing the same status keeps the original change time; a new one
    // restarts it.
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 10_000 }));
    try std.testing.expectEqual(@as(u32, 5), tracker.snapshot(&entries, 15_000)[0].status_age_s);
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 20_000 });
    try std.testing.expectEqual(@as(u32, 15), tracker.snapshot(&entries, 25_000)[0].status_age_s);
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 30_000 }));
    try std.testing.expectEqual(core.AgentStatus.done, tracker.projectedStatus(identity.key).?);
    try std.testing.expectEqual(@as(u32, 1), tracker.snapshot(&entries, 31_000)[0].status_age_s);
}

test "a changed event line advances the revision like a label and clears with its report" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .event = "» Read a.zig", .observed_at_ms = 200 });

    // Same timestamp and status: only the event line differs, and that alone
    // republishes the projection.
    const revision = tracker.revision;
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .event = "» Edit b.zig", .observed_at_ms = 200 }));
    try std.testing.expect(tracker.revision > revision);
    try std.testing.expectEqualStrings("» Edit b.zig", tracker.snapshot(&entries, 400)[0].last_event);

    _ = tracker.expire(400 + types.working_expiry_ms + 1);
    try std.testing.expectEqualStrings("", tracker.snapshot(&entries, 400 + types.working_expiry_ms + 1)[0].last_event);
}

test "managed conversation activity republishes sidebar events without restarting the status age" {
    const ManagedState = @import("ManagedState.zig");
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var transcript: @import("../agent_panes/Transcript.zig") = .{ .value = .{ .pane_id = identity.key.id, .pane_generation = identity.key.generation, .status = .working } };
    try transcript.setTurn("turn-1");
    transcript.update(.{ .id = "message", .role = .assistant, .text = "Checking the parser" });

    try std.testing.expect(tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 100)));
    try std.testing.expectEqualStrings("Checking the parser", tracker.snapshot(&entries, 100)[0].last_event);
    const revision = tracker.revision;
    transcript.update(.{ .id = "command", .role = .tool, .kind = .command, .title = "Command", .detail = "zig build test\n/tmp", .text = "Output must not become the activity" });
    try std.testing.expect(tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 100)));
    try std.testing.expect(tracker.revision > revision);
    try std.testing.expectEqualStrings("zig build test", tracker.snapshot(&entries, 5_100)[0].last_event);
    try std.testing.expectEqual(@as(u32, 5), entries[0].status_age_s);
    try std.testing.expect(!tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 100)));

    transcript.update(.{ .id = "tool", .role = .tool, .kind = .mcp, .title = "docs · lookup" });
    try std.testing.expect(tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 100)));
    try std.testing.expectEqualStrings("docs · lookup", tracker.snapshot(&entries, 100)[0].last_event);
    transcript.update(.{ .id = "tool", .role = .tool, .kind = .mcp, .detail = "Reading documentation", .retain_text = true });
    try std.testing.expect(tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 100)));
    try std.testing.expectEqualStrings("Reading documentation", tracker.snapshot(&entries, 100)[0].last_event);

    transcript.value.status = .ready;
    try std.testing.expect(tracker.observeManaged(identity, ManagedState.fromSnapshot(&transcript.value, 6_000)));
    try std.testing.expectEqualStrings("", tracker.snapshot(&entries, 6_000)[0].last_event);
    try std.testing.expectEqual(core.AgentStatus.done, entries[0].status);
}

test "managed sidebar activity excludes old turns and child output and owns bounded UTF8" {
    const ManagedState = @import("ManagedState.zig");
    var transcript: @import("../agent_panes/Transcript.zig") = .{ .value = .{ .pane_id = try core.pane(7), .pane_generation = 3 } };
    try std.testing.expectEqualStrings("Connecting", ManagedState.fromSnapshot(&transcript.value, 100).event.slice());
    transcript.value.status = .working;
    try transcript.setTurn("old-turn");
    transcript.update(.{ .id = "old", .role = .assistant, .text = "Old activity" });
    try transcript.setTurn("new-turn");
    transcript.update(.{ .id = "prompt", .role = .user, .text = "User prompt" });
    try std.testing.expectEqualStrings("Working", ManagedState.fromSnapshot(&transcript.value, 100).event.slice());

    transcript.update(.{ .id = "message", .role = .assistant, .text = "\n  " ++ "界" ** 40 ++ "\nAnother line" });
    const state = ManagedState.fromSnapshot(&transcript.value, 100);
    try std.testing.expectEqualStrings("界" ** 32, state.event.slice());
    transcript.update(.{ .id = "message", .role = .assistant, .text = "Current root activity" });
    transcript.update(.{ .id = "child", .role = .tool, .kind = .subagent, .text = "Child output" });
    transcript.update(.{ .id = "nested", .role = .assistant, .parent_identity = 1, .text = "Nested output" });
    try std.testing.expectEqualStrings("Current root activity", ManagedState.fromSnapshot(&transcript.value, 100).event.slice());
    try std.testing.expectEqualStrings("界" ** 32, state.event.slice());

    transcript.value.current_turn_id_len = 0;
    try std.testing.expectEqualStrings("Working", ManagedState.fromSnapshot(&transcript.value, 100).event.slice());
    inline for (.{ .ready, .blocked, .failed }) |status| {
        transcript.value.status = status;
        try std.testing.expectEqualStrings("", ManagedState.fromSnapshot(&transcript.value, 100).event.slice());
    }
}
