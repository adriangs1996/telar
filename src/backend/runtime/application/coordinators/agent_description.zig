//! Single-flight scheduling and completion for generated agent titles.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

pub const description = agent_mod.description;
const schema = core.schema;

pub const State = @import("State.zig");

pub const ScheduleResult = enum {
    no_work,
    started,
    failed,
};

pub const Resources = @import("AgentDescriptionResources.zig");

pub const RuntimePort = @import("GenericAgentDescriptionRuntimePort.zig").Type;

pub const Coordinator = @import("GenericAgentDescriptionCoordinator.zig").Type;

pub const Step = enum {
    start,
    persist,
    pump_clients,
};

const Started = @import("Started.zig");

const Capture = @import("AgentDescriptionCapture.zig");

const test_port: RuntimePort(Capture) = .{
    .start = Capture.start,
    .persist = Capture.persist,
    .pump_clients = Capture.pumpClients,
};

pub const TestCoordinator = Coordinator(Capture, test_port);
const generator_arguments = [_][]const u8{"generator"};
const test_command: description.Command = .{
    .arguments = &generator_arguments,
    .timeout_ms = 1_000,
};

const Fixture = @import("Fixture.zig");

fn seedDescription(agents: *agent_mod.Tracker, raw: u64, submitted_input: []const u8) !agent_mod.Identity {
    const identity: agent_mod.Identity = .{
        .key = .{ .id = try schema.id.pane(raw), .generation = raw },
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

fn resultFor(started: Started, status: description.ResultStatus, title: []const u8) description.Result {
    var result: description.Result = .{
        .pane = started.pane,
        .session_id = started.session_id,
        .status = status,
        .title_len = @intCast(title.len),
    };
    @memcpy(result.title[0..title.len], title);
    return result;
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
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
    try std.testing.expectEqual(schema.AgentTitleSource.telar, persisted.source);
    try std.testing.expectEqual(schema.AgentTitleState.failed, persisted.state);
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
    try std.testing.expectEqual(schema.AgentTitleSource.generated, persisted.source);
    try std.testing.expectEqual(schema.AgentTitleState.ready, persisted.state);
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
    try std.testing.expectEqual(schema.AgentTitleSource.telar, persisted.source);
    try std.testing.expectEqual(schema.AgentTitleState.failed, persisted.state);
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
        try std.testing.expectEqual(schema.AgentTitleSource.telar, persisted.source);
        try std.testing.expectEqual(schema.AgentTitleState.failed, persisted.state);
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
    var entries: [agent_mod.max_records]schema.AgentSnapshotEntry = undefined;
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
