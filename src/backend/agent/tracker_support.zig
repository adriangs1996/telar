//! Runtime-owned coordinator for agent observations and projections.
//!
//! The tracker resolves observations to one pane generation, delegates every
//! state transition to that aggregate, and publishes revisioned snapshots.

const Identity = @import("Identity.zig");
const pane_module = @import("telar-core").pane;
const types = @import("types.zig");
const TestProxyObservation = @import("TestProxyObservation.zig");
const AgentProviderType = @import("telar-core").AgentProvider;
const TestReadyPrompt = @import("TestReadyPrompt.zig");
const Tracker = @import("Tracker.zig");
const std = @import("std");
const Agent = @import("Agent.zig");
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;
const AgentStatusType = @import("telar-core").AgentStatus;
const AgentSourceType = @import("telar-core").AgentSource;
const Signal = @import("telar-core").Signal;
const generic_placeholder_module = @import("telar-core").generic_placeholder;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const ResultType = @import("Result.zig");
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const description = @import("description.zig");
const AgentAuthorityType = @import("telar-core").AgentAuthority;
const ProxyExchange = @import("ProxyExchange.zig");
const SessionReferenceType = @import("SessionReference.zig");
const SessionTitle = @import("SessionTitle.zig");
const SessionFileType = @import("SessionFile.zig");
const AgentSessionFileKind = @import("telar-core").AgentSessionFileKind;
const CompletionType = @import("Completion.zig");

pub const AcknowledgeResult = enum {
    unknown_agent,
    unchanged,
    acknowledged,
};

fn testIdentity() !Identity {
    return .{
        .key = .{ .id = try pane_module(7), .generation = 3 },
        .process_id = 42,
        .session_id = .{0xa5} ** 16,
    };
}

fn testIdentityAt(id: u32, generation: u64) !Identity {
    return .{
        .key = .{ .id = try pane_module(id), .generation = generation },
        .process_id = id,
        .session_id = .{@as(u8, @intCast(id))} ** 16,
    };
}

fn testProxy(dialect: types.ApiDialect, phase: types.ProxyPhase, observed_at_ms: i64) TestProxyObservation {
    return .{ .dialect = dialect, .phase = phase, .observed_at_ms = observed_at_ms };
}

fn testReadyPrompt(provider: AgentProviderType, observed_at_ms: i64) TestReadyPrompt {
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

test "display context changes advance the public snapshot revision" {
    var tracker: Tracker = .{};
    const before = tracker.revision;
    tracker.touch();
    try std.testing.expectEqual(before + 1, tracker.revision);
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

    for (0..max_agent_snapshot_entries) |index| {
        const identity = try testIdentityAt(@intCast(index + 1), 1);
        try std.testing.expect(tracker.observeProcess(.{
            .identity = identity,
            .provider = .claude,
            .process_id = identity.process_id,
            .observed_at_ms = 100,
        }));
    }

    const overflow = try testIdentityAt(@intCast(max_agent_snapshot_entries + 1), 1);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(max_agent_snapshot_entries, tracker.snapshot(&entries).len);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.proxy_tls, snapshot[0].source);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 400)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
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
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);

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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
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
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
}

test "a continuing Codex hook cancels pending settlement and only the final Stop can complete" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 300 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 400 });

    const ready: Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 401 });
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 500 });

    for ([_]i64{ 300, 499, 500 }) |stale| {
        _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = stale });
        try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    }

    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 501 });
    try std.testing.expectEqual(AgentStatusType.done, tracker.projectedStatus(identity.key).?);
    _ = tracker.acknowledge(identity.key, 502);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 503 });
    try std.testing.expectEqual(AgentStatusType.ready, tracker.projectedStatus(identity.key).?);
}

test "Codex evidence expiration cannot turn an old prompt into a completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    const ready: Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 101 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 150 });
    _ = tracker.expire(200 + types.working_expiry_ms);
    try std.testing.expectEqual(AgentStatusType.unknown, tracker.projectedStatus(identity.key).?);
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
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
}

test "a Codex model response never completes the agent turn without a new composer" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    const ready: Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 101 });
    _ = observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 200));
    _ = observeTestProxy(&tracker, identity, testProxy(.openai_responses, .provider_turn_completed, 300));
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 301 });
    try std.testing.expectEqual(AgentStatusType.done, tracker.projectedStatus(identity.key).?);
}

test "Codex settlement orders events within one millisecond by the monotonic clock" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .settling, .observed_at_ms = 200, .observed_at_ns = 2_000_000 });
    const ready: Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 1_999_999 });
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeScreen(.{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 2_000_001 });
    try std.testing.expectEqual(AgentStatusType.done, tracker.projectedStatus(identity.key).?);
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
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.proxy_tls, snapshot[0].source);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.ready, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);

    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .working, .confidence = 78 },
        .observed_at_ms = 200,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings(generic_placeholder_module, snapshot[0].session_title);
    try std.testing.expectEqual(AgentTitleStateType.placeholder, snapshot[0].title_state);

    try std.testing.expect(tracker.observeInput(identity.key, "improve the sidebar\r"));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 150)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentTitleStateType.placeholder, snapshot[0].title_state);

    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 200)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentTitleStateType.pending, snapshot[0].title_state);

    var job = tracker.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("improve the sidebar", job.querySlice());
    var result: ResultType = .{
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
    try std.testing.expectEqual(AgentTitleSourceType.generated, finished.source);
    try std.testing.expectEqual(AgentTitleStateType.ready, finished.state);
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("Improve agent sidebar", snapshot[0].session_title);
    try std.testing.expectEqual(AgentTitleSourceType.generated, snapshot[0].title_source);
    try std.testing.expectEqual(AgentTitleStateType.ready, snapshot[0].title_state);
    try std.testing.expect(tracker.nextDescriptionJob() == null);
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

    var result: ResultType = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Generated title".len,
    };
    @memcpy(result.title[0..result.title_len], "Generated title");
    try std.testing.expect(tracker.finishDescription(&result) == null);
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("Release audit", snapshot[0].session_title);
    try std.testing.expectEqual(AgentTitleSourceType.manual, snapshot[0].title_source);
}

test "description backpressure fails the ninth queued request without retry" {
    var tracker: Tracker = .{};
    for (0..description.max_pending_jobs + 1) |index| {
        const raw: u64 = @intCast(index + 1);
        const identity: Identity = .{
            .key = .{ .id = try pane_module(raw), .generation = raw },
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentSourceType.foreground_process, snapshot[0].source);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentProviderType.codex, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.unknown, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(AgentAuthorityType.active, snapshot[0].authority);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.ready, snapshot[0].status);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentAuthorityType.resumed, snapshot[0].authority);
}

test "new network work supersedes an older ready prompt" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .response_finished, 100)));
    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 200)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.anthropic_messages, .request_started, 300)));
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.proxy_tls, snapshot[0].source);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.proxy_tls, snapshot[0].source);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.proxy_tls, snapshot[0].source);
    try std.testing.expectEqual(@as(u8, 99), snapshot[0].confidence);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);

    try std.testing.expect(!tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .response_finished,
        .exchange = exchange,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
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
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);

    try std.testing.expect(tracker.observeProxy(.{
        .identity = identity,
        .dialect = .anthropic_messages,
        .phase = .provider_turn_completed,
        .exchange = second,
        .observed_at_ms = 300,
    }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 300), snapshot[0].observed_at_ms);
}

test "expired agent evidence is removed" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .request_started, 50)));
    try std.testing.expect(observeTestProxy(&tracker, identity, testProxy(.openai_responses, .response_finished, 100)));
    try std.testing.expect(tracker.expire(100 + types.settled_expiry_ms));
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
}

test "a bare shell prompt is not Claude identity" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    try std.testing.expect(!tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .ready, .confidence = 72 },
        .observed_at_ms = 100,
    }));
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqual(@as(usize, 0), tracker.snapshot(&entries).len);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    _ = tracker.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .response_finished,
        .exchange = second,
        .observed_at_ms = 300,
    });
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.codex, 400)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
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

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);

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
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);

    try std.testing.expect(observeTestReadyPrompt(&tracker, identity, testReadyPrompt(.claude, 500)));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.done, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
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
        .key = .{ .id = try pane_module(3), .generation = 2 },
        .process_id = 40,
        .session_id = .{1} ** 16,
    };
    const first = try SessionReferenceType.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 10);

    try std.testing.expect(tracker.observeSessionReference(identity, first));
    try std.testing.expect(!tracker.observeSessionReference(identity, first));
    try std.testing.expectEqualStrings(first.slice(), tracker.sessionReference(identity.key).?.slice());
    try std.testing.expect(tracker.sessionReference(.{ .id = identity.key.id, .generation = 3 }) == null);

    const second = try SessionReferenceType.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 20);
    try std.testing.expect(tracker.observeSessionReference(identity, second));
    try std.testing.expectError(error.InvalidSessionReference, SessionReferenceType.init("-rf", 0));
    try std.testing.expectError(error.InvalidSessionReference, SessionReferenceType.init("a b", 0));
}

test "a restored title waits for the resumed agent and skips title generation" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);

    try std.testing.expect(tracker.restoreTitle(identity.key, title));
    try std.testing.expect(tracker.durableTitle(identity.key) == null);
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 100 }));

    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    const snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", snapshot[0].session_title);
    try std.testing.expectEqual(AgentTitleSourceType.generated, snapshot[0].title_source);
    try std.testing.expectEqual(AgentTitleStateType.ready, snapshot[0].title_state);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", tracker.durableTitle(identity.key).?.slice());

    try std.testing.expect(!tracker.observeInput(identity.key, "fix the tests\r"));
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 }));
    try std.testing.expect(tracker.nextDescriptionJob() == null);
}

test "an agent title outranks generated titles, never clears a manual one and is durable" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();

    try std.testing.expect(try tracker.reportTitle(identity, "Fix proxy"));
    try std.testing.expect(!try tracker.reportTitle(identity, "Fix proxy"));
    try std.testing.expectEqual(AgentTitleSourceType.agent, tracker.durableTitle(identity.key).?.source);
    try std.testing.expectEqualStrings("Fix proxy", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expectError(error.InvalidAgentTitle, tracker.reportTitle(identity, "bad\x1btitle"));

    try std.testing.expect(try tracker.reportTitle(identity, ""));
    try std.testing.expect(tracker.durableTitle(identity.key) == null);
    try std.testing.expect(!try tracker.reportTitle(identity, ""));

    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));
    try std.testing.expect(!try tracker.reportTitle(identity, ""));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expect(try tracker.reportTitle(identity, "Fix proxy again"));
    try std.testing.expectEqual(AgentTitleSourceType.agent, tracker.durableTitle(identity.key).?.source);
}

test "a reported session file is watched, probed once at a time and its names become agent titles" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    const reference = try SessionReferenceType.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100);
    const file: SessionFileType = .{ .kind = .codex_state, .path = "/state_5.sqlite" };

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 100, .session_file = file }));
    try std.testing.expect(tracker.nextSessionFileProbe(2_000, 1_000) == null);
    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200, .session = reference, .session_file = file }));

    const first = tracker.nextSessionFileProbe(2_000, 1_000).?;
    try std.testing.expectEqualStrings("/state_5.sqlite", first.pathSlice());
    try std.testing.expectEqual(AgentSessionFileKind.codex_state, first.kind);
    try std.testing.expect(first.offset == null);
    try std.testing.expect(tracker.nextSessionFileProbe(9_000, 1_000) == null);

    try std.testing.expect(!tracker.finishSessionFileProbe(.{ .key = identity.key, .offset = 300 }, 2_100));
    try std.testing.expect(tracker.nextSessionFileProbe(2_500, 1_000) == null);
    try std.testing.expectEqual(@as(?u64, 300), tracker.nextSessionFileProbe(3_200, 1_000).?.offset);

    var named: CompletionType = .{ .key = identity.key, .offset = 420 };
    named.setTitle("Fix proxy");
    try std.testing.expect(tracker.finishSessionFileProbe(named, 3_300));
    try std.testing.expectEqualStrings("Fix proxy", tracker.durableTitle(identity.key).?.slice());
    try std.testing.expectEqual(AgentTitleSourceType.agent, tracker.durableTitle(identity.key).?.source);
    try std.testing.expect(!tracker.finishSessionFileProbe(named, 3_400));

    // The same name read again after a manual rename does not undo it.
    try std.testing.expect(try tracker.setManualTitle(identity.key, "Release audit"));
    try std.testing.expect(!tracker.finishSessionFileProbe(named, 3_500));
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());

    var cleared: CompletionType = .{ .key = identity.key, .offset = 420 };
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

    const next_generation: Identity = .{ .key = .{ .id = identity.key.id, .generation = identity.key.generation + 1 }, .process_id = 44, .session_id = .{1} ** 16 };
    try std.testing.expect(tracker.restoreTitle(identity.key, title));
    try std.testing.expect(tracker.observeProcess(.{ .identity = next_generation, .provider = .codex, .process_id = 45, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.durableTitle(next_generation.key) == null);
    try std.testing.expectEqualStrings("Release audit", tracker.durableTitle(identity.key).?.slice());
}

test "lifecycle reports outrank screen and proxy evidence until they expire" {
    var tracker: Tracker = .{};
    const identity: Identity = .{
        .key = .{ .id = try pane_module(5), .generation = 1 },
        .process_id = 40,
        .session_id = .{2} ** 16,
    };
    try std.testing.expect(tracker.observeProcess(.{ .identity = identity, .provider = .claude, .process_id = 41, .observed_at_ms = 100 }));
    try std.testing.expect(tracker.observeScreen(.{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(AgentStatusType.blocked, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 300 }));
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    var snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.working, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.lifecycle_report, snapshot[0].source);
    try std.testing.expectEqual(AgentProviderType.claude, snapshot[0].provider);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 400 }));
    try std.testing.expectEqual(AgentStatusType.done, tracker.projectedStatus(identity.key).?);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .exited, .observed_at_ms = 500 }));
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentStatusType.blocked, snapshot[0].status);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);

    try std.testing.expect(tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 600 }));
    _ = tracker.expire(600 + types.working_expiry_ms + 1);
    snapshot = tracker.snapshot(&entries);
    try std.testing.expectEqual(AgentSourceType.screen, snapshot[0].source);
}

test "Pi report renewal keeps a long tool working and loss cannot announce completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .pi, .process_id = 42, .observed_at_ms = 100 });
    try std.testing.expectEqual(AgentStatusType.unknown, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 200 });

    for (1..11) |tick| {
        const now: i64 = 200 + @as(i64, @intCast(tick)) * 30_000;
        _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = now });
        _ = tracker.expire(now + 29_999);
        try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    }

    _ = tracker.expire(300_200 + types.working_expiry_ms);
    try std.testing.expectEqual(AgentStatusType.unknown, tracker.projectedStatus(identity.key).?);
    _ = tracker.observeReport(.{ .identity = identity, .state = .working, .observed_at_ms = 500_000 });
    _ = tracker.observeReport(.{ .identity = identity, .state = .ready, .observed_at_ms = 500_001 });
    try std.testing.expectEqual(AgentStatusType.done, tracker.projectedStatus(identity.key).?);
}

test "Pi model completion followed by local tools is not an agent completion" {
    var tracker: Tracker = .{};
    const identity = try testIdentity();
    _ = tracker.observeProcess(.{ .identity = identity, .provider = .pi, .process_id = 42, .observed_at_ms = 100 });
    const exchange: ProxyExchange = .{ .protocol = .h2, .connection_id = 1, .stream_id = 1 };
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .request_started, .exchange = exchange, .observed_at_ms = 200 });
    _ = tracker.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .provider_turn_completed, .exchange = exchange, .observed_at_ms = 300 });
    try std.testing.expectEqual(AgentStatusType.working, tracker.projectedStatus(identity.key).?);
    _ = tracker.expire(300 + types.working_expiry_ms);
    try std.testing.expectEqual(AgentStatusType.unknown, tracker.projectedStatus(identity.key).?);
}
