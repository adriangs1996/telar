//! Coordination for asynchronous pane graphics processing.

const std = @import("std");
const core = @import("telar-core");
const media_mod = @import("../../../../media/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const media_projection = @import("media_projection.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;
const test_support = @import("../../../tests/support.zig");

pub const diagnostics = core.diagnostics;
pub const Pane = pane_mod.Pane;
pub const PaneKey = pane_mod.PaneKey;
pub const PaneStore = pane_mod.PaneStore;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Work = @import("MediaWork.zig");

pub const Completion = @import("MediaCompletion.zig");

pub const Resources = @import("MediaResources.zig");

pub const RuntimePort = @import("GenericMediaRuntimePort.zig").Type;

pub const Coordinator = @import("GenericMediaCoordinator.zig").Type;

pub const Step = enum {
    quotas,
    synchronize_clients,
    response,
    pump_clients,
    media,
    collect,
};

const Capture = @import("MediaCapture.zig");

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

const ExpectedMetrics = @import("MediaExpectedMetrics.zig");

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
