//! Agent status scenarios: which evidence registers, settles, blocks or
//! completes an agent, and how titles, sessions and resumes follow it.

const RuntimeModel = @import("../RuntimeModel.zig");
const agent_status = @import("../agent_status.zig");
const core = @import("telar-core");
const Identity = @import("../../agent/Identity.zig");
const types = @import("../../agent/types.zig");
const std = @import("std");
const Agent = @import("../../agent/Agent.zig");
const Result = @import("../../agent/Result.zig");
const description = @import("../../agent/description.zig");
const SessionReference = @import("../../agent/SessionReference.zig");
const SessionTitle = @import("../../agent/SessionTitle.zig");
const SessionFile = @import("../../agent/SessionFile.zig");
const Completion = @import("../../agent/Completion.zig");
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

fn observeTestWork(model: *RuntimeModel, identity: Identity, observed_at_ms: i64) bool {
    return agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = observed_at_ms });
}

fn observeTestSettled(model: *RuntimeModel, identity: Identity, observed_at_ms: i64) bool {
    return agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = observed_at_ms });
}

fn testReadyPrompt(provider: core.AgentProvider, observed_at_ms: i64) TestReadyPrompt {
    return .{ .provider = provider, .observed_at_ms = observed_at_ms };
}

fn observeTestReadyPrompt(model: *RuntimeModel, identity: Identity, prompt: TestReadyPrompt) bool {
    return agent_status.observeScreen(model, .{
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

/// A runtime model whose agent state starts empty; these scenarios touch
/// nothing else in it.
fn testModel() !*RuntimeModel {
    const model = try std.testing.allocator.create(RuntimeModel);
    model.agents = .{};
    model.restored_agents = .{};
    model.agent_watches = .{};
    model.agent_revision = 1;
    model.agent_session_revision = 0;
    model.agent_sequence = 0;
    return model;
}

test "an agent without evidence does not consume a projection sequence" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    model.agent_sequence = 41;
    var agent = Agent.init(try testIdentity());

    try std.testing.expect(!agent_status.reproject(model, &agent, 100));
    try std.testing.expectEqual(@as(u64, 41), model.agent_sequence);
    try std.testing.expectEqual(@as(u64, 1), model.agent_revision);
}

test "tracker rejects every observation that would exceed repository capacity" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);

    for (0..core.max_agent_snapshot_entries) |index| {
        const identity = try testIdentityAt(@intCast(index + 1), 1);
        try std.testing.expect(agent_status.observeProcess(model, .{
            .identity = identity,
            .provider = .claude,
            .process_id = identity.process_id,
            .observed_at_ms = 100,
        }));
    }

    const overflow = try testIdentityAt(@intCast(core.max_agent_snapshot_entries + 1), 1);
    try std.testing.expect(!agent_status.observeProcess(model, .{
        .identity = overflow,
        .provider = .claude,
        .process_id = overflow.process_id,
        .observed_at_ms = 200,
    }));
    try std.testing.expect(!agent_status.observeScreen(model, .{
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
    try std.testing.expect(!observeTestWork(model, overflow, 200));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(core.max_agent_snapshot_entries, agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "Codex Stop stays working until a newer input prompt confirms completion" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .codex,
        .process_id = 42,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent_status.observeReport(model, .{
        .identity = identity,
        .state = .working,
        .observed_at_ms = 200,
    }));

    try std.testing.expect(agent_status.observeReport(model, .{
        .identity = identity,
        .state = .settling,
        .observed_at_ms = 300,
    }));
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);

    try std.testing.expect(agent_status.observeScreen(model, .{
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
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentStatus.done, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "Codex active tool reports cannot be settled by a repainted composer" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true },
        .observed_at_ms = 201,
    });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
}

test "a continuing Codex hook cancels pending settlement and only the final Stop can complete" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .settling, .observed_at_ms = 300 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 400 });

    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 401 });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .settling, .observed_at_ms = 500 });

    for ([_]i64{ 300, 499, 500 }) |stale| {
        _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = stale });
        try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
    }

    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 501 });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
    _ = agent_status.acknowledge(model, identity.key, 502);
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 503 });
    try std.testing.expectEqual(core.AgentStatus.ready, agent_status.projectedStatus(model, identity.key).?);
}

test "Codex evidence expiration cannot turn an old prompt into a completion" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 101 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 150 });
    _ = agent_status.expire(model, 200 + types.report_working_expiry_ms);
    try std.testing.expectEqual(core.AgentStatus.unknown, agent_status.projectedStatus(model, identity.key).?);
}

test "new Codex activity supersedes an older SessionStart or Interrupt ready report" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 200 });
    _ = agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .codex, .status = .working, .confidence = 94 },
        .observed_at_ms = 201,
    });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
}

test "Codex settlement orders events within one millisecond by the monotonic clock" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .settling, .observed_at_ms = 200, .observed_at_ns = 2_000_000 });
    const ready: core.Signal = .{ .provider = .codex, .status = .ready, .confidence = 94, .ready_confirmed = true };
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 1_999_999 });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
    _ = agent_status.observeScreen(model, .{ .identity = identity, .signal = ready, .observed_at_ms = 200, .observed_at_ns = 2_000_001 });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
}

test "an older Codex prompt cannot overrule current lifecycle work" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .codex,
        .process_id = 42,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent_status.observeReport(model, .{
        .identity = identity,
        .state = .working,
        .observed_at_ms = 300,
    }));

    try std.testing.expect(!agent_status.observeScreen(model, .{
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
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
}

test "screen text cannot register an agent without independent evidence" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(!agent_status.observeScreen(model, .{
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
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(@as(usize, 0), snapshot.len);
}

test "foreground process establishes agent identity without screen branding" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);

    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .working, .confidence = 78 },
        .observed_at_ms = 200,
    }));
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
    try std.testing.expectEqual(@as(u32, 84), snapshot[0].process_id);
}

test "first working turn starts one generated session title" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .codex,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqualStrings(core.generic_placeholder, snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(agent_status.observeInput(model, identity.key, "improve the sidebar\r"));
    try std.testing.expect(observeTestReadyPrompt(model, identity, testReadyPrompt(.codex, 150)));
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentTitleState.placeholder, snapshot[0].title_state);

    try std.testing.expect(observeTestWork(model, identity, 200));
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentTitleState.pending, snapshot[0].title_state);

    var job = agent_status.nextDescriptionJob(model).?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("improve the sidebar", job.querySlice());
    var result: Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Improve agent sidebar".len,
    };
    @memcpy(result.title[0..result.title_len], "Improve agent sidebar");
    const finished = agent_status.finishDescription(model, &result).?;
    @memset(result.title[0..result.title_len], 'x');
    try std.testing.expectEqualDeep(job.pane, finished.pane);
    try std.testing.expectEqualSlices(u8, &job.session_id, &finished.session_id);
    try std.testing.expectEqualStrings("Improve agent sidebar", finished.titleSlice());
    try std.testing.expectEqual(core.AgentTitleSource.generated, finished.source);
    try std.testing.expectEqual(core.AgentTitleState.ready, finished.state);
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqualStrings("Improve agent sidebar", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(core.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expect(agent_status.nextDescriptionJob(model) == null);
}

test "manual title wins over a late generated result" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent_status.observeInput(model, identity.key, "fix tests\r"));
    try std.testing.expect(observeTestWork(model, identity, 200));
    var job = agent_status.nextDescriptionJob(model).?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expect(try agent_status.setManualTitle(model, identity.key, "Release audit"));

    var result: Result = .{
        .pane = job.pane,
        .session_id = job.session_id,
        .status = .success,
        .title_len = "Generated title".len,
    };
    @memcpy(result.title[0..result.title_len], "Generated title");
    try std.testing.expect(agent_status.finishDescription(model, &result) == null);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqualStrings("Release audit", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.manual, snapshot[0].title_source);
}

test "description backpressure fails the ninth queued request without retry" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    for (0..description.max_pending_jobs + 1) |index| {
        const raw: u64 = @intCast(index + 1);
        const identity: Identity = .{
            .key = .{ .id = try core.pane(raw), .generation = raw },
            .process_id = @intCast(raw),
            .session_id = @splat(@intCast(raw)),
        };
        try std.testing.expect(agent_status.observeProcess(model, .{
            .identity = identity,
            .provider = .codex,
            .process_id = @intCast(raw),
            .observed_at_ms = 100,
        }));
        try std.testing.expect(agent_status.observeInput(model, identity.key, "do work\r"));
        try std.testing.expect(observeTestWork(model, identity, 200));
    }
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
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
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(!agent_status.observeScreen(model, .{
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
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
}

test "foreground process exit removes all evidence for that session" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(agent_status.clearProcess(model, identity.key));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "new foreground process replaces prior session evidence" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .unknown, .status = .blocked, .confidence = 88 },
        .observed_at_ms = 200,
    }));
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .codex,
        .process_id = 85,
        .observed_at_ms = 300,
    }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentProvider.codex, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.unknown, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
    try std.testing.expectEqual(core.AgentAuthority.active, snapshot[0].authority);
    try std.testing.expectEqual(@as(u32, 85), snapshot[0].process_id);
}

test "confirmed Claude prompt refreshes branded identity" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(agent_status.observeProcess(model, .{
        .identity = identity,
        .provider = .claude,
        .process_id = 84,
        .observed_at_ms = 50,
    }));
    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{
            .provider = .claude,
            .status = .ready,
            .confidence = 90,
            .identity_confirmed = true,
        },
        .observed_at_ms = 100,
    }));
    try std.testing.expect(observeTestReadyPrompt(model, identity, testReadyPrompt(.claude, 200)));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);
    try std.testing.expectEqual(core.AgentStatus.ready, snapshot[0].status);
    try std.testing.expectEqual(@as(i64, 200), snapshot[0].observed_at_ms);
}

test "expired agent evidence is removed" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(observeTestWork(model, identity, 50));
    try std.testing.expect(observeTestSettled(model, identity, 100));
    try std.testing.expect(agent_status.expire(model, 100 + types.settled_expiry_ms));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "expiration removes every adjacent stale aggregate" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const first = try testIdentityAt(1, 1);
    const second = try testIdentityAt(2, 1);

    try std.testing.expect(observeTestWork(model, first, 50));
    try std.testing.expect(observeTestSettled(model, first, 100));
    try std.testing.expect(observeTestWork(model, second, 50));
    try std.testing.expect(observeTestSettled(model, second, 100));
    try std.testing.expect(agent_status.expire(model, 100 + types.settled_expiry_ms));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "a bare shell prompt is not Claude identity" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(!agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .ready, .confidence = 72 },
        .observed_at_ms = 100,
    }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "session references attach to the exact generation and replace only on change" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity: Identity = .{
        .key = .{ .id = try core.pane(3), .generation = 2 },
        .process_id = 40,
        .session_id = .{1} ** 16,
    };
    const first = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 10);

    try std.testing.expect(agent_status.observeSessionReference(model, identity, first));
    try std.testing.expect(!agent_status.observeSessionReference(model, identity, first));
    try std.testing.expectEqualStrings(first.slice(), agent_status.sessionReference(model, identity.key).?.slice());
    try std.testing.expect(agent_status.sessionReference(model, .{ .id = identity.key.id, .generation = 3 }) == null);

    const second = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 20);
    try std.testing.expect(agent_status.observeSessionReference(model, identity, second));
    try std.testing.expectError(error.InvalidSessionReference, SessionReference.init("-rf", 0));
    try std.testing.expectError(error.InvalidSessionReference, SessionReference.init("a b", 0));
}

test "a restored title waits for the resumed agent and skips title generation" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    const title = try SessionTitle.init("Investigate proxy lifecycle", .generated);

    try std.testing.expect(agent_status.restoreTitle(model, identity.key, title));
    try std.testing.expect(agent_status.durableTitle(model, identity.key) == null);
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 100 }));

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", snapshot[0].session_title);
    try std.testing.expectEqual(core.AgentTitleSource.generated, snapshot[0].title_source);
    try std.testing.expectEqual(core.AgentTitleState.ready, snapshot[0].title_state);
    try std.testing.expectEqualStrings("Investigate proxy lifecycle", agent_status.durableTitle(model, identity.key).?.slice());

    try std.testing.expect(!agent_status.observeInput(model, identity.key, "fix the tests\r"));
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 }));
    try std.testing.expect(agent_status.nextDescriptionJob(model) == null);
}

test "a pending resume survives observation ticks without inventing an active agent" {
    const ResumeSession = @import("../../agent/ResumeSession.zig");
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0);
    const session = try ResumeSession.init(.claude, reference);
    const title = try SessionTitle.init("Keep resume metadata", .manual);
    try std.testing.expect(agent_status.restoreSession(model, identity.key, session));
    try std.testing.expect(agent_status.restoreTitle(model, identity.key, title));

    _ = agent_status.expire(model, 10_000);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 10_000).len);
    try std.testing.expect(agent_status.hasRestoredSession(model, session));
    try std.testing.expect(agent_status.resumeSession(model, identity.key).?.eql(session));
    try std.testing.expectEqualStrings(title.slice(), agent_status.checkpointTitle(model, identity.key).?.slice());
    try std.testing.expect(agent_status.resumeSession(model, .{ .id = identity.key.id, .generation = identity.key.generation + 1 }) == null);

    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 11_000 }));
    try std.testing.expect(!agent_status.hasRestoredSession(model, session));
    try std.testing.expect(agent_status.resumeSession(model, identity.key).?.eql(session));
    try std.testing.expectEqualStrings(title.slice(), agent_status.durableTitle(model, identity.key).?.slice());
    try std.testing.expect(agent_status.remove(model, identity.key));
    try std.testing.expect(agent_status.resumeSession(model, identity.key) == null);
}

test "a pending resume is discarded for another provider or a different reported session" {
    const ResumeSession = @import("../../agent/ResumeSession.zig");
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 0);
    const session = try ResumeSession.init(.claude, reference);
    const title = try SessionTitle.init("Old session", .manual);

    const other_provider = try testModel();
    defer std.testing.allocator.destroy(other_provider);
    try std.testing.expect(agent_status.restoreSession(other_provider, identity.key, session));
    try std.testing.expect(agent_status.restoreTitle(other_provider, identity.key, title));
    try std.testing.expect(agent_status.observeReport(other_provider, .{ .identity = identity, .state = .ready, .observed_at_ms = 99, .session = reference }));
    try std.testing.expect(agent_status.durableTitle(other_provider, identity.key) == null);
    try std.testing.expect(agent_status.observeProcess(other_provider, .{ .identity = identity, .provider = .codex, .process_id = 43, .observed_at_ms = 100 }));
    try std.testing.expect(agent_status.resumeSession(other_provider, identity.key) == null);
    try std.testing.expect(agent_status.durableTitle(other_provider, identity.key) == null);

    const other_session = try testModel();
    defer std.testing.allocator.destroy(other_session);
    try std.testing.expect(agent_status.restoreSession(other_session, identity.key, session));
    try std.testing.expect(agent_status.restoreTitle(other_session, identity.key, title));
    try std.testing.expect(agent_status.observeReport(other_session, .{ .identity = identity, .state = .ready, .observed_at_ms = 99 }));
    try std.testing.expect(agent_status.durableTitle(other_session, identity.key) == null);
    const replacement = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0001", 100);
    try std.testing.expect(agent_status.observeSessionReference(other_session, identity, replacement));
    try std.testing.expect(!agent_status.hasRestoredSession(other_session, session));
    try std.testing.expect(agent_status.durableTitle(other_session, identity.key) == null);
    try std.testing.expect(agent_status.observeProcess(other_session, .{ .identity = identity, .provider = .claude, .process_id = 43, .observed_at_ms = 101 }));
    try std.testing.expectEqualStrings(replacement.slice(), agent_status.resumeSession(other_session, identity.key).?.reference.slice());
}

test "an agent title outranks generated titles, never clears a manual one and is durable" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();

    try std.testing.expect(try agent_status.reportTitle(model, identity, "Fix proxy"));
    try std.testing.expect(!try agent_status.reportTitle(model, identity, "Fix proxy"));
    try std.testing.expectEqual(core.AgentTitleSource.agent, agent_status.durableTitle(model, identity.key).?.source);
    try std.testing.expectEqualStrings("Fix proxy", agent_status.durableTitle(model, identity.key).?.slice());
    try std.testing.expectError(error.InvalidAgentTitle, agent_status.reportTitle(model, identity, "bad\x1btitle"));

    try std.testing.expect(try agent_status.reportTitle(model, identity, ""));
    try std.testing.expect(agent_status.durableTitle(model, identity.key) == null);
    try std.testing.expect(!try agent_status.reportTitle(model, identity, ""));

    try std.testing.expect(try agent_status.setManualTitle(model, identity.key, "Release audit"));
    try std.testing.expect(!try agent_status.reportTitle(model, identity, ""));
    try std.testing.expectEqualStrings("Release audit", agent_status.durableTitle(model, identity.key).?.slice());
    try std.testing.expect(try agent_status.reportTitle(model, identity, "Fix proxy again"));
    try std.testing.expectEqual(core.AgentTitleSource.agent, agent_status.durableTitle(model, identity.key).?.source);
}

test "a reported session file is watched, probed once at a time and its names become agent titles" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    const reference = try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 100);
    const file: SessionFile = .{ .kind = .codex_state, .path = "/state_5.sqlite" };

    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 100, .session_file = file }));
    try std.testing.expect(agent_status.nextSessionFileProbe(model, 2_000, 1_000) == null);
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200, .session = reference, .session_file = file }));

    const first = agent_status.nextSessionFileProbe(model, 2_000, 1_000).?;
    try std.testing.expectEqualStrings("/state_5.sqlite", first.pathSlice());
    try std.testing.expectEqual(core.AgentSessionFileKind.codex_state, first.kind);
    try std.testing.expect(first.offset == null);
    try std.testing.expect(agent_status.nextSessionFileProbe(model, 9_000, 1_000) == null);

    try std.testing.expect(!agent_status.finishSessionFileProbe(model, .{ .key = identity.key, .offset = 300 }, 2_100));
    try std.testing.expect(agent_status.nextSessionFileProbe(model, 2_500, 1_000) == null);
    try std.testing.expectEqual(@as(?u64, 300), agent_status.nextSessionFileProbe(model, 3_200, 1_000).?.offset);

    var named: Completion = .{ .key = identity.key, .offset = 420 };
    named.setTitle("Fix proxy");
    try std.testing.expect(agent_status.finishSessionFileProbe(model, named, 3_300));
    try std.testing.expectEqualStrings("Fix proxy", agent_status.durableTitle(model, identity.key).?.slice());
    try std.testing.expectEqual(core.AgentTitleSource.agent, agent_status.durableTitle(model, identity.key).?.source);
    try std.testing.expect(!agent_status.finishSessionFileProbe(model, named, 3_400));

    // The same name read again after a manual rename does not undo it.
    try std.testing.expect(try agent_status.setManualTitle(model, identity.key, "Release audit"));
    try std.testing.expect(!agent_status.finishSessionFileProbe(model, named, 3_500));
    try std.testing.expectEqualStrings("Release audit", agent_status.durableTitle(model, identity.key).?.slice());

    var cleared: Completion = .{ .key = identity.key, .offset = 420 };
    cleared.setTitle("");
    try std.testing.expect(!agent_status.finishSessionFileProbe(model, cleared, 3_600));
    try std.testing.expectEqualStrings("Release audit", agent_status.durableTitle(model, identity.key).?.slice());

    try std.testing.expect(agent_status.remove(model, identity.key));
    try std.testing.expect(agent_status.nextSessionFileProbe(model, 9_000, 1_000) == null);
    try std.testing.expectEqual(@as(usize, 0), model.agent_watches.count());
}

test "a restored title is dropped with its pane and never reaches another generation" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    const title = try SessionTitle.init("Release audit", .manual);

    try std.testing.expect(agent_status.restoreTitle(model, identity.key, title));
    try std.testing.expect(!agent_status.remove(model, identity.key));
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 43, .observed_at_ms = 100 }));
    try std.testing.expect(agent_status.durableTitle(model, identity.key) == null);

    // A pane id holds one generation at a time: the next generation's agent
    // exists only after the previous one is gone, and never inherits its
    // restored title.
    const next_generation: Identity = .{ .key = .{ .id = identity.key.id, .generation = identity.key.generation + 1 }, .process_id = 44, .session_id = .{1} ** 16 };
    try std.testing.expect(agent_status.remove(model, identity.key));
    try std.testing.expect(agent_status.restoreTitle(model, identity.key, title));
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = next_generation, .provider = .codex, .process_id = 45, .observed_at_ms = 100 }));
    try std.testing.expect(agent_status.durableTitle(model, next_generation.key) == null);

    try std.testing.expect(agent_status.remove(model, next_generation.key));
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = 46, .observed_at_ms = 100 }));
    try std.testing.expectEqualStrings("Release audit", agent_status.durableTitle(model, identity.key).?.slice());
}

test "lifecycle reports outrank screen evidence until they expire" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity: Identity = .{
        .key = .{ .id = try core.pane(5), .generation = 1 },
        .process_id = 40,
        .session_id = .{2} ** 16,
    };
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 41, .observed_at_ms = 100 }));
    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 200,
    }));
    try std.testing.expectEqual(core.AgentStatus.blocked, agent_status.projectedStatus(model, identity.key).?);

    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 300 }));
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.lifecycle_report, snapshot[0].source);
    try std.testing.expectEqual(core.AgentProvider.claude, snapshot[0].provider);

    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 400 }));
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);

    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .exited, .observed_at_ms = 500 }));
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);

    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 600 }));
    _ = agent_status.expire(model, 600 + types.report_working_expiry_ms + 1);
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentSource.screen, snapshot[0].source);
}

test "Pi report renewal keeps a long tool working and loss cannot announce completion" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .pi, .process_id = 42, .observed_at_ms = 100 });
    try std.testing.expectEqual(core.AgentStatus.unknown, agent_status.projectedStatus(model, identity.key).?);
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });

    for (1..11) |tick| {
        const now: i64 = 200 + @as(i64, @intCast(tick)) * 30_000;
        _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = now });
        _ = agent_status.expire(model, now + 29_999);
        try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
    }

    _ = agent_status.expire(model, 300_200 + types.report_working_expiry_ms);
    try std.testing.expectEqual(core.AgentStatus.unknown, agent_status.projectedStatus(model, identity.key).?);
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 500_000 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 500_001 });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
}

test "a blocked report names its reason and event and a blocked screen alone names none" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 }));

    try std.testing.expect(agent_status.observeReport(model, .{
        .identity = identity,
        .state = .blocked,
        .blocked_reason = .question,
        .event = "Which database?",
        .observed_at_ms = 200,
    }));
    var snapshot = agent_status.snapshot(&model.agents, &entries, 200);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentBlockedReason.question, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("Which database?", snapshot[0].last_event);

    // A working report replaces the question with the tool call.
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .event = "» Edit src/proxy.zig", .observed_at_ms = 300 }));
    snapshot = agent_status.snapshot(&model.agents, &entries, 300);
    try std.testing.expectEqual(core.AgentBlockedReason.none, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("» Edit src/proxy.zig", snapshot[0].last_event);

    // Without a report, a blocked screen has no named reason and no line.
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .exited, .observed_at_ms = 400 }));
    try std.testing.expect(agent_status.observeScreen(model, .{
        .identity = identity,
        .signal = .{ .provider = .claude, .status = .blocked, .confidence = 88, .identity_confirmed = true },
        .observed_at_ms = 500,
    }));
    snapshot = agent_status.snapshot(&model.agents, &entries, 500);
    try std.testing.expectEqual(core.AgentStatus.blocked, snapshot[0].status);
    try std.testing.expectEqual(core.AgentBlockedReason.other, snapshot[0].blocked_reason);
    try std.testing.expectEqualStrings("", snapshot[0].last_event);
}

test "the status age follows the last status change and never advances the revision" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expect(agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 1_000 }));
    try std.testing.expectEqual(@as(u32, 0), agent_status.snapshot(&model.agents, &entries, 500)[0].status_age_s);
    try std.testing.expectEqual(@as(u32, 4), agent_status.snapshot(&model.agents, &entries, 5_999)[0].status_age_s);

    const revision = model.agent_revision;
    try std.testing.expectEqual(@as(u32, 60), agent_status.snapshot(&model.agents, &entries, 61_000)[0].status_age_s);
    try std.testing.expectEqual(revision, model.agent_revision);

    // Renewing the same status keeps the original change time; a new one
    // restarts it.
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 10_000 }));
    try std.testing.expectEqual(@as(u32, 5), agent_status.snapshot(&model.agents, &entries, 15_000)[0].status_age_s);
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 20_000 });
    try std.testing.expectEqual(@as(u32, 15), agent_status.snapshot(&model.agents, &entries, 25_000)[0].status_age_s);
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 30_000 }));
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
    try std.testing.expectEqual(@as(u32, 1), agent_status.snapshot(&model.agents, &entries, 31_000)[0].status_age_s);
}

test "a changed event line advances the revision like a label and clears with its report" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .event = "» Read a.zig", .observed_at_ms = 200 });

    // Same timestamp and status: only the event line differs, and that alone
    // republishes the projection.
    const revision = model.agent_revision;
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .event = "» Edit b.zig", .observed_at_ms = 200 }));
    try std.testing.expect(model.agent_revision > revision);
    try std.testing.expectEqualStrings("» Edit b.zig", agent_status.snapshot(&model.agents, &entries, 400)[0].last_event);

    _ = agent_status.expire(model, 400 + types.report_working_expiry_ms + 1);
    try std.testing.expectEqualStrings("", agent_status.snapshot(&model.agents, &entries, 400 + types.report_working_expiry_ms + 1)[0].last_event);
}

test "a continuing helper renews reported work past its expiry once per margin" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    const revision = model.agent_revision;

    try std.testing.expect(!agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = 300 }));
    try std.testing.expectEqual(revision, model.agent_revision);

    const renewed_at: i64 = 200 + types.report_working_expiry_ms - 1;
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = renewed_at }));
    try std.testing.expect(!agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = renewed_at + 1 }));

    _ = agent_status.expire(model, 200 + types.report_working_expiry_ms + 1);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    var snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentStatus.working, snapshot[0].status);
    try std.testing.expectEqual(core.AgentSource.lifecycle_report, snapshot[0].source);

    _ = agent_status.expire(model, renewed_at + types.report_working_expiry_ms);
    snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
}

test "a continuing helper cannot hide a prompt, revive finished work or register an agent" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    try std.testing.expect(!agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = 100 }));
    try std.testing.expect(agent_status.projectedStatus(model, identity.key) == null);

    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .blocked, .blocked_reason = .permission, .observed_at_ms = 200 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = 300 });
    try std.testing.expectEqual(core.AgentStatus.blocked, agent_status.projectedStatus(model, identity.key).?);

    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 400 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = 500 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = 600 });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);

    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 700 });
    const expired_at: i64 = 700 + types.report_working_expiry_ms;
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = expired_at });
    _ = agent_status.expire(model, expired_at);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    const snapshot = agent_status.snapshot(&model.agents, &entries, 0);
    try std.testing.expectEqual(core.AgentSource.foreground_process, snapshot[0].source);
}

test "a turn waiting on helpers stays working through the idle prompt" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .waiting, .event = "waiting for 1 background agent", .observed_at_ms = 300 });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);

    const revision = model.agent_revision;
    try std.testing.expect(!agent_status.observeReport(model, .{ .identity = identity, .state = .idle, .observed_at_ms = 60_300 }));
    try std.testing.expectEqual(revision, model.agent_revision);
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqualStrings("waiting for 1 background agent", agent_status.snapshot(&model.agents, &entries, 60_300)[0].last_event);

    // The helper's own tool calls keep the wait alive past its first expiry.
    const renewed_at: i64 = 300 + types.report_working_expiry_ms - 1;
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .continuing, .observed_at_ms = renewed_at }));
    try std.testing.expect(!agent_status.observeReport(model, .{ .identity = identity, .state = .idle, .observed_at_ms = renewed_at + 1 }));

    // The helper's result starts a new turn, and its Stop settles the agent.
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = renewed_at + 2 });
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .ready, .observed_at_ms = renewed_at + 3 });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
}

test "the idle prompt settles work no wait holds and an expired wait" {
    const model = try testModel();
    defer std.testing.allocator.destroy(model);
    const identity = try testIdentity();
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .claude, .process_id = 42, .observed_at_ms = 100 });

    // Without a wait, the idle prompt settles like ready.
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 });
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .idle, .observed_at_ms = 60_200 }));
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);

    // A wait no helper renewed stops vetoing the idle prompt once it expires.
    _ = agent_status.observeReport(model, .{ .identity = identity, .state = .waiting, .observed_at_ms = 70_000 });
    try std.testing.expectEqual(core.AgentStatus.working, agent_status.projectedStatus(model, identity.key).?);
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .idle, .observed_at_ms = 70_000 + types.report_working_expiry_ms }));
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(model, identity.key).?);
}

const TestReadyPrompt = struct {
    provider: core.AgentProvider,
    observed_at_ms: i64,
};
