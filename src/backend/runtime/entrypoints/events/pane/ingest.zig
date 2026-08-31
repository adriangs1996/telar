//! Post-ingest coordination for one pane generation.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../../pane/root.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;
const test_support = @import("../../../tests/support.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Stats = pane_mod.PaneIngestStats;

pub const Completion = struct {
    pane: PaneKey,
    result: anyerror!Stats,
};

/// Output-read borrow handed to the runtime actor scheduler.
pub const Read = struct {
    io: Io,
    pane: *Pane,
};

pub const Resources = struct {
    io: Io,
    panes: *PaneStore,
    metrics: *RuntimeMetrics,
};

/// Defines the asynchronous work and runtime lifecycle effects used after VT
/// ingestion.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        schedule_observation: *const fn (*Context, *Pane) anyerror!void,
        schedule_media: *const fn (*Context, *Pane) anyerror!void,
        refresh_clients: *const fn (*Context, *Pane) void,
        schedule_response: *const fn (*Context, *Pane) anyerror!void,
        start_read: *const fn (*Context, Read) anyerror!void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched post-ingest coordinator.
///
/// ```zig
/// const IngestCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane repository and telemetry.
        ///
        /// ```zig
        /// var coordinator = IngestCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Settles one generation-matched ingest. Success synchronizes domain,
        /// background observers, client projections, PTY responses, and the
        /// next read in that order. Ingest failure retires the pane output.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: Completion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            pane.completeOutputIngest();
            const stats = completion.result catch {
                _ = pane.requestClose();
                pane.finishPtyOutput();
                port.collect(coordinator.context);
                return;
            };

            if (comptime diagnostics.enabled) {
                coordinator.resources.metrics.ingest.observe(stats.elapsed_ns);
            }

            pane.applyPendingResize() catch {
                _ = pane.requestClose();
            };
            try port.schedule_observation(coordinator.context, pane);
            try port.schedule_media(coordinator.context, pane);
            port.refresh_clients(coordinator.context, pane);
            try port.schedule_response(coordinator.context, pane);

            const read: Read = .{
                .io = coordinator.resources.io,
                .pane = pane,
            };
            const read_started = pane.beginPtyOutputRead();
            std.debug.assert(read_started);
            port.start_read(coordinator.context, read) catch |err| {
                pane.cancelPtyOutputRead();
                return err;
            };

            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }
    };
}

const Step = enum {
    observation,
    media,
    refresh_clients,
    response,
    read,
    collect,
    pump_clients,
};

const Capture = struct {
    steps: [7]Step = undefined,
    len: usize = 0,
    failure: ?Step = null,
    expected_size: ?schema.TerminalSize = null,
    observation_saw_released_ingest: bool = false,
    observation_saw_expected_size: bool = false,
    refresh_saw_expected_size: bool = false,
    read_saw_borrow: bool = false,

    fn record(capture: *Capture, step: Step) !void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;

        if (capture.failure == step) {
            return error.SchedulerUnavailable;
        }
    }

    fn scheduleObservation(capture: *Capture, pane: *Pane) !void {
        capture.observation_saw_released_ingest = !pane.ingest_pending;
        capture.observation_saw_expected_size = capture.hasExpectedSize(pane);
        try capture.record(.observation);
    }

    fn scheduleMedia(capture: *Capture, _: *Pane) !void {
        try capture.record(.media);
    }

    fn refreshClients(capture: *Capture, pane: *Pane) void {
        capture.refresh_saw_expected_size = capture.hasExpectedSize(pane);
        capture.record(.refresh_clients) catch unreachable;
    }

    fn scheduleResponse(capture: *Capture, _: *Pane) !void {
        try capture.record(.response);
    }

    fn startRead(capture: *Capture, read: Read) !void {
        capture.read_saw_borrow = read.pane.output_pending;
        try capture.record(.read);
    }

    fn collect(capture: *Capture) void {
        capture.record(.collect) catch unreachable;
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients) catch unreachable;
    }

    fn hasExpectedSize(capture: *const Capture, pane: *const Pane) bool {
        const expected = capture.expected_size orelse return true;
        return std.meta.eql(expected, pane.size);
    }
};

const test_port: RuntimePort(Capture) = .{
    .schedule_observation = Capture.scheduleObservation,
    .schedule_media = Capture.scheduleMedia,
    .refresh_clients = Capture.refreshClients,
    .schedule_response = Capture.scheduleResponse,
    .start_read = Capture.startRead,
    .collect = Capture.collect,
    .pump_clients = Capture.pumpClients,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn testCoordinator(capture: *Capture, panes: *PaneStore, metrics: *RuntimeMetrics) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn insertFixturePane(fixture: *test_support.PaneFixture, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    _ = fixture.pane.beginOutputIngest(1);
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectIngestTiming(metrics: *const RuntimeMetrics, elapsed_ns: u64) !void {
    const expected_count: u64 = if (comptime diagnostics.enabled) 1 else 0;
    const expected_elapsed: u64 = if (comptime diagnostics.enabled) elapsed_ns else 0;
    try std.testing.expectEqual(expected_count, metrics.ingest.count);
    try std.testing.expectEqual(expected_elapsed, metrics.ingest.total_ns);
    try std.testing.expectEqual(expected_elapsed, metrics.ingest.max_ns);
}

test "ingest failure closes the pane output before collection" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = error.IngestFailed,
    });

    try expectSteps(&capture, &.{.collect});
    try std.testing.expect(fixture.pane.close_requested);
    try std.testing.expect(fixture.pane.output_done);
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expectEqual(@as(u64, 0), fixture.metrics.ingest.count);
}

test "success synchronizes every dependent before starting the next read" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{ .elapsed_ns = 37 },
    });

    try expectSteps(&capture, &.{ .observation, .media, .refresh_clients, .response, .read, .collect, .pump_clients });
    try std.testing.expect(capture.observation_saw_released_ingest);
    try std.testing.expect(capture.read_saw_borrow);
    try std.testing.expect(fixture.pane.output_pending);
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.actor_count);
    try expectIngestTiming(&fixture.metrics, 37);
    fixture.pane.cancelPtyOutputRead();
}

test "a pending resize commits before observers and client projections" {
    const resized: schema.TerminalSize = .{ .cols = 30, .rows = 8 };
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.requestResize(resized);
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .expected_size = resized };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{ .elapsed_ns = 1 },
    });

    try std.testing.expect(capture.observation_saw_expected_size);
    try std.testing.expect(capture.refresh_saw_expected_size);
    try std.testing.expectEqualDeep(resized, fixture.pane.size);
    try std.testing.expect(fixture.pane.pending_size == null);
    fixture.pane.cancelPtyOutputRead();
}

test "a failed deferred resize retires the pane but preserves effect ordering" {
    const resized: schema.TerminalSize = .{ .cols = 30, .rows = 8 };
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.requestResize(resized);
    fixture.failNextPaneAllocation();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{ .elapsed_ns = 1 },
    });

    try expectSteps(&capture, &.{ .observation, .media, .refresh_clients, .response, .read, .collect, .pump_clients });
    try std.testing.expect(fixture.pane.close_requested);
    try std.testing.expectEqualDeep(test_support.PaneFixture.initial_size, fixture.pane.size);
    try std.testing.expectEqualDeep(resized, fixture.pane.pending_size.?);
    fixture.pane.cancelPtyOutputRead();
}

test "observation failure stops every later post-ingest effect" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .failure = .observation };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{},
    }));

    try expectSteps(&capture, &.{.observation});
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "media failure stops before client projection and PTY work" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .failure = .media };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{},
    }));

    try expectSteps(&capture, &.{ .observation, .media });
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "response failure preserves refreshed clients and skips the next read" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .failure = .response };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{},
    }));

    try expectSteps(&capture, &.{ .observation, .media, .refresh_clients, .response });
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "read start failure releases its pane borrow and skips lifecycle effects" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .failure = .read };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{},
    }));

    try expectSteps(&capture, &.{ .observation, .media, .refresh_clients, .response, .read });
    try std.testing.expect(capture.read_saw_borrow);
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "a stale generation cannot release a live ingest borrow" {
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.ingest_pending = true;
    pane.actor_count = 1;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &metrics);

    try coordinator.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = .{},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try expectSteps(&capture, &.{});
    try std.testing.expect(pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelOutputIngest();
}
