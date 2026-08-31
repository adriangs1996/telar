//! Single-flight scheduling and completion for generated agent titles.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const description = agent_mod.description;
const schema = core.schema;

pub const State = struct {
    pending: bool = false,

    /// Reports whether a generator actor still owns the global description
    /// slot, even if its agent aggregate has already been retired.
    ///
    /// ```zig
    /// if (state.isPending()) {
    ///     return;
    /// }
    /// ```
    pub fn isPending(state: *const State) bool {
        return state.pending;
    }

    fn begin(state: *State) void {
        std.debug.assert(!state.pending);
        state.pending = true;
    }

    fn complete(state: *State) void {
        std.debug.assert(state.pending);
        state.pending = false;
    }
};

pub const ScheduleResult = enum {
    no_work,
    started,
    failed,
};

pub const Resources = struct {
    agents: *agent_mod.Tracker,
    state: *State,
    command: ?description.Command,
};

/// Defines generator startup, durable title projection, and client delivery
/// bound by the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, description.Command, description.Job) anyerror!void,
        persist: *const fn (*Context, agent_mod.DescriptionFinished) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched agent-description coordinator.
///
/// ```zig
/// const AgentDescriptionCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's agent tracker, generator configuration, and
        /// single-flight actor state.
        ///
        /// ```zig
        /// var coordinator = AgentDescriptionCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one configured generator job. Scheduler failure is
        /// committed as a failed aggregate result; the caller remains
        /// responsible for the delivery opportunity surrounding this call.
        ///
        /// ```zig
        /// _ = coordinator.schedule();
        /// ```
        pub fn schedule(coordinator: *Self) ScheduleResult {
            const command = coordinator.resources.command orelse return .no_work;
            if (coordinator.resources.state.isPending()) {
                return .no_work;
            }

            var job = coordinator.resources.agents.nextDescriptionJob() orelse return .no_work;
            defer std.crypto.secureZero(u8, &job.query);

            port.start(coordinator.context, command, job) catch {
                _ = coordinator.commit(.{
                    .pane = job.pane,
                    .session_id = job.session_id,
                    .status = .failed,
                });
                return .failed;
            };

            coordinator.resources.state.begin();
            return .started;
        }

        /// Releases the completed actor slot, applies only an exact aggregate
        /// result, persists the validated domain event, starts the next queued
        /// job, then gives clients one delivery opportunity.
        ///
        /// ```zig
        /// coordinator.handle(result);
        /// ```
        pub fn handle(coordinator: *Self, result: description.Result) void {
            coordinator.resources.state.complete();
            _ = coordinator.commit(result);
            _ = coordinator.schedule();
            port.pump_clients(coordinator.context);
        }

        fn commit(coordinator: *Self, result: description.Result) bool {
            const finished = coordinator.resources.agents.finishDescription(&result) orelse return false;
            port.persist(coordinator.context, finished);
            return true;
        }
    };
}

const Step = enum {
    start,
    persist,
    pump_clients,
};

const Started = struct {
    pane: pane_mod.PaneKey = undefined,
    session_id: [16]u8 = undefined,
    query_matches: bool = false,
};

const Capture = struct {
    steps: [8]Step = undefined,
    len: usize = 0,
    start_failure: bool = false,
    expected_query: []const u8 = "",
    state: ?*const State = null,
    starts: [2]Started = undefined,
    start_count: usize = 0,
    start_saw_idle: bool = false,
    persisted: [2]agent_mod.DescriptionFinished = undefined,
    persisted_count: usize = 0,
    persist_saw_idle: bool = false,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn start(capture: *Capture, _: description.Command, job: description.Job) !void {
        capture.record(.start);
        capture.start_saw_idle = !capture.state.?.isPending();
        std.debug.assert(capture.start_count < capture.starts.len);
        capture.starts[capture.start_count] = .{
            .pane = job.pane,
            .session_id = job.session_id,
            .query_matches = std.mem.eql(u8, capture.expected_query, job.querySlice()),
        };
        capture.start_count += 1;

        if (capture.start_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn persist(capture: *Capture, finished: agent_mod.DescriptionFinished) void {
        capture.record(.persist);
        capture.persist_saw_idle = !capture.state.?.isPending();
        std.debug.assert(capture.persisted_count < capture.persisted.len);
        capture.persisted[capture.persisted_count] = finished;
        capture.persisted_count += 1;
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }
};

const test_port: RuntimePort(Capture) = .{
    .start = Capture.start,
    .persist = Capture.persist,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);
const generator_arguments = [_][]const u8{"generator"};
const test_command: description.Command = .{
    .arguments = &generator_arguments,
    .timeout_ms = 1_000,
};

const Fixture = struct {
    agents: agent_mod.Tracker = .{},
    state: State = .{},
    capture: Capture = .{},

    fn coordinator(fixture: *Fixture, command: ?description.Command) TestCoordinator {
        fixture.capture.state = &fixture.state;
        return TestCoordinator.init(&fixture.capture, .{
            .agents = &fixture.agents,
            .state = &fixture.state,
            .command = command,
        });
    }
};

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
        .provider = .codex,
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
