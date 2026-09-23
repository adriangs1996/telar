//! Observation-worker completions exercise the same concrete operations as Runtime.update.
const std = @import("std");
const core = @import("telar-core");
const EventFixture = @import("EventFixture.zig");
const RequestFixture = @import("RequestFixture.zig");
const agent_description = @import("../agent_description.zig");
const proxy_observation = @import("../proxy_observation.zig");
const agent_identity = @import("../agent_identity.zig");
const description = @import("../../agent/description.zig");
const AgentResult = @import("../../agent/Result.zig");
const Tracker = @import("../../agent/Tracker.zig");
const Identity = @import("../../agent/Identity.zig");
const Job = @import("../../agent/Job.zig");
const middleware = @import("../../proxy/middleware.zig");
const ProxyTestFiles = @import("../resources/ProxyTestFiles.zig");
const ProxyRuntime = @import("../resources/ProxyRuntime.zig");

fn seedDescription(agents: *Tracker, number: u64) !Identity {
    const identity: Identity = .{
        .key = .{ .id = @enumFromInt(number), .generation = number },
        .process_id = @intCast(number + 10),
        .session_id = @splat(@intCast(number)),
    };
    _ = agents.observeProcess(.{ .identity = identity, .provider = .codex, .process_id = identity.process_id, .observed_at_ms = 100 });
    try std.testing.expect(agents.observeInput(identity.key, "refactor proxy\r"));
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .request_started,
        .exchange = .{ .protocol = .h2, .connection_id = number, .stream_id = 1 },
        .observed_at_ms = 200,
    }));
    return identity;
}

fn resultFor(job: Job, status: description.ResultStatus, title: []const u8) AgentResult {
    var result: AgentResult = .{ .pane = job.pane, .session_id = job.session_id, .status = status, .title_len = @intCast(title.len) };
    @memcpy(result.title[0..title.len], title);
    return result;
}

test "runtime disabled descriptions leave queued work and its global actor slot untouched" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    _ = try seedDescription(&model.agents, 1);
    agent_description.start(model);
    try std.testing.expect(!model.agent_description_pending);
    var job = model.agents.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("refactor proxy", job.querySlice());
}

test "runtime description completion commits valid output and classifies every generator failure" {
    for (std.enums.values(description.ResultStatus)) |status| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const model = &fixture.runtime.model;
        _ = try seedDescription(&model.agents, 1);
        var job = model.agents.nextDescriptionJob().?;
        defer std.crypto.secureZero(u8, &job.query);
        model.agent_description_pending = true;
        _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, status, "Refactor proxy") });
        try std.testing.expect(!model.agent_description_pending);
        var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
        const entry = model.agents.snapshot(&entries, 0)[0];
        try std.testing.expectEqual(if (status == .success) core.AgentTitleState.ready else .failed, entry.title_state);
        try std.testing.expectEqualStrings(if (status == .success) "Refactor proxy" else "New agent session", entry.session_title);
        try std.testing.expectEqual(if (status == .success) core.AgentTitleSource.generated else .telar, entry.title_source);
    }
}

test "runtime invalid generated titles and late manual-title completions retain aggregate authority" {
    for ([_]bool{ false, true }) |manual| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const model = &fixture.runtime.model;
        const identity = try seedDescription(&model.agents, 1);
        var job = model.agents.nextDescriptionJob().?;
        defer std.crypto.secureZero(u8, &job.query);
        model.agent_description_pending = true;
        if (manual) {
            _ = try model.agents.setManualTitle(identity.key, "Manual title");
        }
        _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, .success, "invalid\ntitle") });
        try std.testing.expect(!model.agent_description_pending);
        var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
        const entry = model.agents.snapshot(&entries, 0)[0];
        try std.testing.expectEqualStrings(if (manual) "Manual title" else "New agent session", entry.session_title);
        try std.testing.expectEqual(if (manual) core.AgentTitleState.ready else .failed, entry.title_state);
    }
}

test "runtime description admission failure commits failure without retaining the actor slot" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.failScheduling();
    const model = fixture.model;
    _ = try seedDescription(fixture.agents, 1);
    model.agent_description_options = .{ .arguments = &.{"generator"}, .timeout_ms = 1000 };
    agent_description.start(model);
    try std.testing.expect(!model.agent_description_pending);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(core.AgentTitleState.failed, fixture.agents.snapshot(&entries, 0)[0].title_state);
}

test "runtime retired description completion releases the actor slot and cannot change the next agent" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    const identity = try seedDescription(&model.agents, 1);
    var job = model.agents.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    model.agent_description_pending = true;
    try std.testing.expect(model.agents.remove(identity.key));
    const replacement = try seedDescription(&model.agents, 2);
    _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, .success, "Retired title") });
    try std.testing.expect(!model.agent_description_pending);
    var next = model.agents.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &next.query);
    try std.testing.expectEqualDeep(replacement.key, next.pane);
}

test "runtime proxy receive and rearm failures preserve agent authority" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.request.runtime.update(.{ .proxy_event = error.ReceiveFailed });
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) == null);
    var files = try ProxyTestFiles.init(std.testing.io);
    defer files.deinit();
    var proxy = try ProxyRuntime.init(std.testing.io, std.testing.allocator, .{ .config = files.config(), .system_trusted = false });
    defer proxy.deinit();
    std.mem.swap(ProxyRuntime, &fixture.model.resources.proxy, &proxy);
    defer std.mem.swap(ProxyRuntime, &fixture.model.resources.proxy, &proxy);
    fixture.failScheduling();
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{
        .proxy_event = proxy_observation.eventFor(fixture.pane, .request_started, .h2),
    }));
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.proxy_observations);
}

test "runtime proxy observations reject stale generations and auxiliary traffic" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stale = proxy_observation.eventFor(fixture.pane, .request_started, .http11);
    stale.pane.generation += 1;
    _ = try fixture.request.runtime.update(.{ .proxy_event = stale });
    try std.testing.expectEqual(@as(u64, 1), fixture.metrics.stale_pane_events);
    _ = try fixture.request.runtime.update(.{ .proxy_event = proxy_observation.eventFor(fixture.pane, .auxiliary_request_started, .h2) });
    try std.testing.expect(fixture.agents.projectedStatus(fixture.pane.key()) == null);
}

test "runtime provider turn completion updates Claude across HTTP protocols" {
    for ([_]middleware.Protocol{ .http11, .h2 }) |protocol| {
        var fixture: EventFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        var observation = proxy_observation.eventFor(fixture.pane, .request_started, protocol);
        observation.dialect = .anthropic_messages;
        observation.stream_id = if (protocol == .http11) 0 else 23;
        _ = try fixture.request.runtime.update(.{ .proxy_event = observation });
        try std.testing.expectEqual(core.AgentStatus.working, fixture.agents.projectedStatus(fixture.pane.key()).?);
        observation.phase = .provider_turn_completed;
        observation.observed_at_ms += 1;
        _ = try fixture.request.runtime.update(.{ .proxy_event = observation });
        try std.testing.expectEqual(core.AgentStatus.done, fixture.agents.projectedStatus(fixture.pane.key()).?);
    }
}

test "runtime maintenance failure preserves evidence and a successful tick expires it" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const identity = agent_identity.fromPane(fixture.pane);
    _ = fixture.agents.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .request_started, .exchange = .{ .protocol = .h2, .connection_id = 19, .stream_id = 23 }, .observed_at_ms = 1 });
    _ = fixture.agents.observeProxy(.{ .identity = identity, .dialect = .openai_responses, .phase = .provider_turn_completed, .exchange = .{ .protocol = .h2, .connection_id = 19, .stream_id = 23 }, .observed_at_ms = 2 });
    _ = try fixture.request.runtime.update(.{ .agent_tick = error.TimerFailed });
    try std.testing.expectEqual(core.AgentStatus.done, fixture.agents.projectedStatus(identity.key).?);
    fixture.failScheduling();
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .agent_tick = {} }));
    try std.testing.expectEqual(core.AgentStatus.done, fixture.agents.projectedStatus(identity.key).?);
    fixture.model.select = fixture.request.runtime.loop.selector();
    _ = try fixture.request.runtime.update(.{ .agent_tick = {} });
    try std.testing.expect(fixture.agents.projectedStatus(identity.key) != .done);
}
