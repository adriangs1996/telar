//! Single-flight scheduling and completion for generated agent titles.

const GenericAgentDescriptionRuntimePort = @import("GenericAgentDescriptionRuntimePort.zig").Type;
const AgentDescriptionCapture = @import("AgentDescriptionCapture.zig");
const GenericAgentDescriptionCoordinator = @import("GenericAgentDescriptionCoordinator.zig").Type;
const CommandType = @import("../../../agent/Command.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const IdentityType = @import("../../../agent/Identity.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");
const Started = @import("Started.zig");
const description = @import("../../../agent/description.zig");
const ResultType = @import("../../../agent/Result.zig");
const Fixture = @import("Fixture.zig");
const AgentTitleSourceType = @import("telar-core").AgentTitleSource;
const AgentTitleStateType = @import("telar-core").AgentTitleState;
const max_agent_snapshot_entries = @import("telar-core").max_agent_snapshot_entries;
const AgentSnapshotEntryType = @import("telar-core").AgentSnapshotEntry;

pub const ScheduleResult = enum {
    no_work,
    started,
    failed,
};

pub const Step = enum {
    start,
    persist,
    pump_clients,
};

const test_port: GenericAgentDescriptionRuntimePort(AgentDescriptionCapture) = .{
    .start = AgentDescriptionCapture.start,
    .persist = AgentDescriptionCapture.persist,
    .pump_clients = AgentDescriptionCapture.pumpClients,
};

pub const TestCoordinator = GenericAgentDescriptionCoordinator(AgentDescriptionCapture, test_port);
const generator_arguments = [_][]const u8{"generator"};
const test_command: CommandType = .{
    .arguments = &generator_arguments,
    .timeout_ms = 1_000,
};

fn seedDescription(agents: *TrackerType, raw: u64, submitted_input: []const u8) !IdentityType {
    const identity: IdentityType = .{
        .key = .{ .id = try pane_module(raw), .generation = raw },
        .process_id = @intCast(raw + 10),
        .session_id = @splat(@intCast(raw)),
    };
    try std.testing.expect(agents.observeProcess(.{
        .identity = identity,
        .provider = .codex,
        .process_id = identity.process_id,
        .observed_at_ms = 100,
    }));
    try std.testing.expect(agents.observeInput(identity.key, submitted_input));
    try std.testing.expect(agents.observeProxy(.{
        .identity = identity,
        .dialect = .openai_responses,
        .phase = .request_started,
        .exchange = .{
            .protocol = .h2,
            .connection_id = raw,
            .stream_id = 1,
        },
        .observed_at_ms = 200,
    }));
    return identity;
}

fn resultFor(started: Started, status: description.ResultStatus, title: []const u8) ResultType {
    var result: ResultType = .{
        .pane = started.pane,
        .session_id = started.session_id,
        .status = status,
        .title_len = @intCast(title.len),
    };
    @memcpy(result.title[0..title.len], title);
    return result;
}

fn expectSteps(capture: *const AgentDescriptionCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "disabled generation leaves queued work untouched" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    var coordinator = fixture.coordinator(null);

    try std.testing.expectEqual(ScheduleResult.no_work, coordinator.schedule());

    try expectSteps(&fixture.capture, &.{});
    try std.testing.expect(!fixture.state.isPending());
    var queued = fixture.agents.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &queued.query);
    try std.testing.expectEqualStrings("refactor proxy", queued.querySlice());
}

test "successful scheduling claims the global actor slot after startup" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    fixture.capture.expected_query = "refactor proxy";
    var coordinator = fixture.coordinator(test_command);

    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());
    try std.testing.expectEqual(ScheduleResult.no_work, coordinator.schedule());

    try expectSteps(&fixture.capture, &.{.start});
    try std.testing.expect(fixture.capture.start_saw_idle);
    try std.testing.expect(fixture.capture.starts[0].query_matches);
    try std.testing.expect(fixture.state.isPending());
}

test "startup failure commits an owned failed title without claiming the slot" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    fixture.capture.expected_query = "refactor proxy";
    fixture.capture.start_failure = true;
    var coordinator = fixture.coordinator(test_command);

    try std.testing.expectEqual(ScheduleResult.failed, coordinator.schedule());

    try expectSteps(&fixture.capture, &.{ .start, .persist });
    try std.testing.expect(!fixture.state.isPending());
    try std.testing.expect(fixture.capture.start_saw_idle);
    try std.testing.expect(fixture.capture.persist_saw_idle);
    const persisted = fixture.capture.persisted[0];
    try std.testing.expectEqualStrings("", persisted.titleSlice());
    try std.testing.expectEqual(AgentTitleSourceType.telar, persisted.source);
    try std.testing.expectEqual(AgentTitleStateType.failed, persisted.state);
}

test "successful completion persists the aggregate event before pumping" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    fixture.capture.expected_query = "refactor proxy";
    var coordinator = fixture.coordinator(test_command);
    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());

    coordinator.handle(resultFor(fixture.capture.starts[0], .success, "Refactor proxy"));

    try expectSteps(&fixture.capture, &.{ .start, .persist, .pump_clients });
    try std.testing.expect(!fixture.state.isPending());
    try std.testing.expect(fixture.capture.persist_saw_idle);
    const persisted = fixture.capture.persisted[0];
    try std.testing.expectEqualStrings("Refactor proxy", persisted.titleSlice());
    try std.testing.expectEqual(AgentTitleSourceType.generated, persisted.source);
    try std.testing.expectEqual(AgentTitleStateType.ready, persisted.state);
}

test "invalid successful output persists the aggregate's failed projection" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    var coordinator = fixture.coordinator(test_command);
    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());

    coordinator.handle(resultFor(fixture.capture.starts[0], .success, "invalid\ntitle"));

    try expectSteps(&fixture.capture, &.{ .start, .persist, .pump_clients });
    const persisted = fixture.capture.persisted[0];
    try std.testing.expectEqualStrings("", persisted.titleSlice());
    try std.testing.expectEqual(AgentTitleSourceType.telar, persisted.source);
    try std.testing.expectEqual(AgentTitleStateType.failed, persisted.state);
}

test "every unsuccessful generator result persists one failed projection" {
    const statuses = [_]description.ResultStatus{
        .unavailable,
        .timeout,
        .invalid_output,
        .failed,
    };

    for (statuses) |status| {
        var fixture: Fixture = .{};
        _ = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
        var coordinator = fixture.coordinator(test_command);
        try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());

        coordinator.handle(resultFor(fixture.capture.starts[0], status, "ignored"));

        try expectSteps(&fixture.capture, &.{ .start, .persist, .pump_clients });
        const persisted = fixture.capture.persisted[0];
        try std.testing.expectEqualStrings("", persisted.titleSlice());
        try std.testing.expectEqual(AgentTitleSourceType.telar, persisted.source);
        try std.testing.expectEqual(AgentTitleStateType.failed, persisted.state);
        try std.testing.expect(!fixture.state.isPending());
    }
}

test "a stale generated result cannot overwrite or persist a manual title" {
    var fixture: Fixture = .{};
    const identity = try seedDescription(&fixture.agents, 1, "refactor proxy\r");
    var coordinator = fixture.coordinator(test_command);
    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());
    try std.testing.expect(try fixture.agents.setManualTitle(identity.key, "Manual title"));

    coordinator.handle(resultFor(fixture.capture.starts[0], .success, "Generated title"));

    try expectSteps(&fixture.capture, &.{ .start, .pump_clients });
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.persisted_count);
    try std.testing.expect(!fixture.state.isPending());
    var entries: [max_agent_snapshot_entries]AgentSnapshotEntryType = undefined;
    try std.testing.expectEqualStrings("Manual title", fixture.agents.snapshot(&entries)[0].session_title);
}

test "completion starts the next queued job before one client pump" {
    var fixture: Fixture = .{};
    _ = try seedDescription(&fixture.agents, 1, "first task\r");
    _ = try seedDescription(&fixture.agents, 2, "second task\r");
    fixture.capture.expected_query = "first task";
    var coordinator = fixture.coordinator(test_command);
    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());

    fixture.capture.expected_query = "second task";
    coordinator.handle(resultFor(fixture.capture.starts[0], .success, "First title"));

    try expectSteps(&fixture.capture, &.{ .start, .persist, .start, .pump_clients });
    try std.testing.expectEqual(@as(usize, 2), fixture.capture.start_count);
    try std.testing.expect(fixture.capture.starts[1].query_matches);
    try std.testing.expect(fixture.state.isPending());
}

test "a retired running aggregate holds the slot until its stale completion" {
    var fixture: Fixture = .{};
    const first = try seedDescription(&fixture.agents, 1, "first task\r");
    var coordinator = fixture.coordinator(test_command);
    try std.testing.expectEqual(ScheduleResult.started, coordinator.schedule());
    const first_start = fixture.capture.starts[0];
    try std.testing.expect(fixture.agents.remove(first.key));
    _ = try seedDescription(&fixture.agents, 2, "second task\r");

    try std.testing.expectEqual(ScheduleResult.no_work, coordinator.schedule());
    coordinator.handle(resultFor(first_start, .success, "Stale title"));

    try expectSteps(&fixture.capture, &.{ .start, .start, .pump_clients });
    try std.testing.expectEqual(@as(usize, 2), fixture.capture.start_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.capture.persisted_count);
    try std.testing.expect(fixture.state.isPending());
}
