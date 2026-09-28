//! Observation-worker completions exercise the same concrete operations as Runtime.update.
const RuntimeModel = @import("../RuntimeModel.zig");
const agent_status = @import("../agent_status.zig");
const std = @import("std");
const core = @import("telar-core");
const EventFixture = @import("EventFixture.zig");
const RequestFixture = @import("RequestFixture.zig");
const agent_description = @import("../agent_description.zig");
const agent_identity = @import("../agent_identity.zig");
const description = @import("../../agent/description.zig");
const AgentResult = @import("../../agent/Result.zig");
const Identity = @import("../../agent/Identity.zig");
const Job = @import("../../agent/Job.zig");

fn seedDescription(model: *RuntimeModel, number: u64) !Identity {
    const identity: Identity = .{
        .key = .{ .id = @enumFromInt(number), .generation = number },
        .process_id = @intCast(number + 10),
        .session_id = @splat(@intCast(number)),
    };
    _ = agent_status.observeProcess(model, .{ .identity = identity, .provider = .codex, .process_id = identity.process_id, .observed_at_ms = 100 });
    try std.testing.expect(agent_status.observeInput(model, identity.key, "refactor proxy\r"));
    try std.testing.expect(agent_status.observeReport(model, .{ .identity = identity, .state = .working, .observed_at_ms = 200 }));
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
    _ = try seedDescription(model, 1);
    agent_description.start(model);
    try std.testing.expect(!model.agent_description_pending);
    var job = agent_status.nextDescriptionJob(model).?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("refactor proxy", job.querySlice());
}

test "runtime description completion commits valid output and classifies every generator failure" {
    for (std.enums.values(description.ResultStatus)) |status| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const model = &fixture.runtime.model;
        _ = try seedDescription(model, 1);
        var job = agent_status.nextDescriptionJob(model).?;
        defer std.crypto.secureZero(u8, &job.query);
        model.agent_description_pending = true;
        _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, status, "Refactor proxy") });
        try std.testing.expect(!model.agent_description_pending);
        var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
        const entry = agent_status.snapshot(&model.agents, &entries, 0)[0];
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
        const identity = try seedDescription(model, 1);
        var job = agent_status.nextDescriptionJob(model).?;
        defer std.crypto.secureZero(u8, &job.query);
        model.agent_description_pending = true;
        if (manual) {
            _ = try agent_status.setManualTitle(model, identity.key, "Manual title");
        }
        _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, .success, "invalid\ntitle") });
        try std.testing.expect(!model.agent_description_pending);
        var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
        const entry = agent_status.snapshot(&model.agents, &entries, 0)[0];
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
    _ = try seedDescription(fixture.model, 1);
    model.agent_description_options = .{ .arguments = &.{"generator"}, .timeout_ms = 1000 };
    agent_description.start(model);
    try std.testing.expect(!model.agent_description_pending);
    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(core.AgentTitleState.failed, agent_status.snapshot(&fixture.model.agents, &entries, 0)[0].title_state);
}

test "runtime retired description completion releases the actor slot and cannot change the next agent" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    const identity = try seedDescription(model, 1);
    var job = agent_status.nextDescriptionJob(model).?;
    defer std.crypto.secureZero(u8, &job.query);
    model.agent_description_pending = true;
    try std.testing.expect(agent_status.remove(model, identity.key));
    const replacement = try seedDescription(model, 2);
    _ = try fixture.runtime.update(.{ .agent_description = resultFor(job, .success, "Retired title") });
    try std.testing.expect(!model.agent_description_pending);
    var next = agent_status.nextDescriptionJob(model).?;
    defer std.crypto.secureZero(u8, &next.query);
    try std.testing.expectEqualDeep(replacement.key, next.pane);
}

test "runtime maintenance failure preserves evidence and a successful tick expires it" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const identity = agent_identity.fromPane(fixture.pane);
    _ = agent_status.observeReport(fixture.model, .{ .identity = identity, .state = .working, .observed_at_ms = 1 });
    _ = agent_status.observeReport(fixture.model, .{ .identity = identity, .state = .ready, .observed_at_ms = 2 });
    _ = try fixture.request.runtime.update(.{ .agent_tick = error.TimerFailed });
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(fixture.model, identity.key).?);
    fixture.failScheduling();
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .agent_tick = {} }));
    try std.testing.expectEqual(core.AgentStatus.done, agent_status.projectedStatus(fixture.model, identity.key).?);
    fixture.model.select = fixture.request.runtime.loop.selector();
    _ = try fixture.request.runtime.update(.{ .agent_tick = {} });
    try std.testing.expect(agent_status.projectedStatus(fixture.model, identity.key) != .done);
}
