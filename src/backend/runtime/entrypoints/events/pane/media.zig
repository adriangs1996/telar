//! Coordination for asynchronous pane graphics processing.

const std = @import("std");
const core = @import("telar-core");
const media_mod = @import("../../../../media/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const media_projection = @import("media_projection.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;
const test_support = @import("../../../tests/support.zig");

const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Work = struct {
    pane: *Pane,
    current_size: core.schema.TerminalSize,
};

pub const Completion = struct {
    pane: PaneKey,
    stats: media_mod.Stats,
};

pub const Resources = struct {
    panes: *PaneStore,
    metrics: *RuntimeMetrics,
};

/// Defines media actor startup and runtime-owned graphics projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Work) anyerror!void,
        enforce_quotas: *const fn (*Context, *Pane) void,
        synchronize_clients: *const fn (*Context, *Pane, bool) media_projection.Stats,
        schedule_response: *const fn (*Context, *Pane) anyerror!void,
        pump_clients: *const fn (*Context) void,
        collect: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched media coordinator.
///
/// ```zig
/// const MediaCoordinator = Coordinator(Context, port);
/// ```
pub fn Coordinator(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane repository and graphics telemetry.
        ///
        /// ```zig
        /// var coordinator = MediaCoordinator.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one media actor. Async-start failure releases the
        /// pane and sealed-batch borrow.
        ///
        /// ```zig
        /// try coordinator.schedule(pane);
        /// ```
        pub fn schedule(coordinator: *Self, pane: *Pane) !void {
            const borrow = pane.beginMediaProcessing() orelse return;
            const work: Work = .{ .pane = pane, .current_size = borrow.current_size };

            port.start(coordinator.context, work) catch |err| {
                pane.cancelMediaProcessing();
                return err;
            };
        }

        /// Settles one generation-matched media batch, projects its bounded
        /// graphics state to clients, schedules PTY replies, then rearms any
        /// queued media work between the two client-pump opportunities.
        ///
        /// ```zig
        /// try coordinator.handle(completion);
        /// ```
        pub fn handle(coordinator: *Self, completion: Completion) !void {
            const pane = coordinator.resources.panes.resolve(completion.pane) orelse {
                coordinator.resources.metrics.stale_pane_events += 1;
                return;
            };

            pane.completeMediaProcessing();
            coordinator.observeMetrics(completion.stats);
            port.enforce_quotas(coordinator.context, pane);
            pane.refreshGraphicsProjection();

            const projection = port.synchronize_clients(coordinator.context, pane, completion.stats.reset);
            if (comptime diagnostics.enabled) {
                coordinator.resources.metrics.graphics_transfers_staged +|= projection.staged;
            }

            try port.schedule_response(coordinator.context, pane);
            port.pump_clients(coordinator.context);
            try coordinator.schedule(pane);
            port.collect(coordinator.context);
            port.pump_clients(coordinator.context);
        }

        fn observeMetrics(coordinator: *Self, stats: media_mod.Stats) void {
            if (comptime !diagnostics.enabled) {
                return;
            }

            coordinator.resources.metrics.media_bytes +|= stats.output_bytes;
            coordinator.resources.metrics.media_discarded_frames +|= stats.discarded_frames;
            coordinator.resources.metrics.media_unavailable_frames +|= stats.unavailable_frames;
            coordinator.resources.metrics.media_forwarded_frames +|= stats.forwarded_frames;

            if (stats.failed) {
                coordinator.resources.metrics.media_failures +|= 1;
            }

            if (stats.reset) {
                coordinator.resources.metrics.media_resets +|= 1;
            }
        }
    };
}

const Step = enum {
    quotas,
    synchronize_clients,
    response,
    pump_clients,
    media,
    collect,
};

const Capture = struct {
    steps: [7]Step = undefined,
    len: usize = 0,
    start_failure: bool = false,
    response_failure: bool = false,
    projection: media_projection.Stats = .{},
    reset: bool = false,
    synchronize_saw_idle_media: bool = false,
    synchronize_saw_projection: bool = false,
    start_saw_borrow: bool = false,
    started_work: ?Work = null,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn start(capture: *Capture, work: Work) !void {
        capture.record(.media);
        capture.started_work = work;
        capture.start_saw_borrow = work.pane.media.worker != null and work.pane.actor_count != 0;

        if (capture.start_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn enforceQuotas(capture: *Capture, _: *Pane) void {
        capture.record(.quotas);
    }

    fn synchronizeClients(capture: *Capture, pane: *Pane, reset: bool) media_projection.Stats {
        capture.record(.synchronize_clients);
        capture.reset = reset;
        capture.synchronize_saw_idle_media = pane.media.worker == null;
        capture.synchronize_saw_projection = pane.graphics_present and pane.graphics_revision != 0;
        return capture.projection;
    }

    fn scheduleResponse(capture: *Capture, _: *Pane) !void {
        capture.record(.response);

        if (capture.response_failure) {
            return error.SchedulerUnavailable;
        }
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients);
    }

    fn collect(capture: *Capture) void {
        capture.record(.collect);
    }
};

const test_port: RuntimePort(Capture) = .{
    .start = Capture.start,
    .enforce_quotas = Capture.enforceQuotas,
    .synchronize_clients = Capture.synchronizeClients,
    .schedule_response = Capture.scheduleResponse,
    .pump_clients = Capture.pumpClients,
    .collect = Capture.collect,
};

const TestCoordinator = Coordinator(Capture, test_port);

fn testCoordinator(capture: *Capture, panes: *PaneStore, metrics: *RuntimeMetrics) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .panes = panes,
        .metrics = metrics,
    });
}

fn beginFixtureMedia(fixture: *test_support.PaneFixture, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    fixture.pane.queueMediaOutput("media");
    try std.testing.expect(fixture.pane.beginMediaProcessing() != null);
}

fn queueFollowUp(fixture: *test_support.PaneFixture) void {
    fixture.pane.queueMediaOutput("follow-up");
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

const ExpectedMetrics = struct {
    output_bytes: u64 = 0,
    discarded: u64 = 0,
    unavailable: u64 = 0,
    forwarded: u64 = 0,
    failures: u64 = 0,
    resets: u64 = 0,
    staged: u64 = 0,
};

fn expectMetrics(metrics: *const RuntimeMetrics, expected: ExpectedMetrics) !void {
    const actual = if (comptime diagnostics.enabled) expected else ExpectedMetrics{};
    try std.testing.expectEqual(actual.output_bytes, metrics.media_bytes);
    try std.testing.expectEqual(actual.discarded, metrics.media_discarded_frames);
    try std.testing.expectEqual(actual.unavailable, metrics.media_unavailable_frames);
    try std.testing.expectEqual(actual.forwarded, metrics.media_forwarded_frames);
    try std.testing.expectEqual(actual.failures, metrics.media_failures);
    try std.testing.expectEqual(actual.resets, metrics.media_resets);
    try std.testing.expectEqual(actual.staged, metrics.graphics_transfers_staged);
}

test "media completion refreshes graphics before clients and preserves effect order" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    fixture.pane.graphics_revision = std.math.maxInt(u64);
    try fixture.addRgbaImage(7);
    var capture: Capture = .{ .projection = .{ .staged = 2 } };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{
            .output_bytes = 13,
            .discarded_frames = 2,
            .unavailable_frames = 3,
            .forwarded_frames = 5,
            .failed = true,
            .reset = true,
        },
    });

    try expectSteps(&capture, &.{ .quotas, .synchronize_clients, .response, .pump_clients, .collect, .pump_clients });
    try std.testing.expect(capture.reset);
    try std.testing.expect(capture.synchronize_saw_idle_media);
    try std.testing.expect(capture.synchronize_saw_projection);
    try std.testing.expect(fixture.pane.graphics_present);
    try std.testing.expectEqual(@as(u64, 1), fixture.pane.graphics_revision);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expect(fixture.pane.media.worker == null);
    try expectMetrics(&fixture.metrics, .{
        .output_bytes = 13,
        .discarded = 2,
        .unavailable = 3,
        .forwarded = 5,
        .failures = 1,
        .resets = 1,
        .staged = 2,
    });
}

test "pending media is rearmed between the two client pumps" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{ .pane = fixture.pane.key(), .stats = .{} });

    try expectSteps(&capture, &.{ .quotas, .synchronize_clients, .response, .pump_clients, .media, .collect, .pump_clients });
    try std.testing.expect(capture.start_saw_borrow);
    try std.testing.expectEqualDeep(fixture.pane.size, capture.started_work.?.current_size);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.actor_count);
    fixture.pane.cancelMediaProcessing();
}

test "response scheduling failure stops before pumping and media rearm" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    fixture.pane.graphics_present = true;
    queueFollowUp(&fixture);
    var capture: Capture = .{ .response_failure = true };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
    }));

    try expectSteps(&capture, &.{ .quotas, .synchronize_clients, .response });
    try std.testing.expect(!fixture.pane.graphics_present);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expect(fixture.pane.media.hasPending());
}

test "media start failure rolls its borrow back after the first client pump" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: Capture = .{ .start_failure = true };
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, coordinator.handle(.{
        .pane = fixture.pane.key(),
        .stats = .{},
    }));

    try expectSteps(&capture, &.{ .quotas, .synchronize_clients, .response, .pump_clients, .media });
    try std.testing.expect(capture.start_saw_borrow);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try std.testing.expect(fixture.pane.media.worker == null);
    try std.testing.expect(!fixture.pane.media.hasPending());
}

test "a stale generation cannot release a live media borrow" {
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.actor_count = 1;
    pane.media.worker = 1;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var coordinator = testCoordinator(&capture, &panes, &metrics);

    try coordinator.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .stats = .{},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try expectSteps(&capture, &.{});
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try std.testing.expectEqual(@as(?u1, 1), pane.media.worker);
}
