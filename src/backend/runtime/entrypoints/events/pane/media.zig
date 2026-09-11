//! Coordination for asynchronous pane graphics processing.

const GenericMediaRuntimePort = @import("GenericMediaRuntimePort.zig").Type;
const MediaCapture = @import("MediaCapture.zig");
const GenericMediaCoordinator = @import("GenericMediaCoordinator.zig").Type;
const PaneStore = @import("../../../../pane/PaneStore.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const PaneFixtureType = @import("../../../tests/PaneFixture.zig");
const std = @import("std");
const MediaExpectedMetrics = @import("MediaExpectedMetrics.zig");
const enabled_module = @import("telar-core").enabled;
const Pane = @import("../../../../pane/Pane.zig");

pub const Step = enum {
    quotas,
    synchronize_clients,
    response,
    pump_clients,
    media,
    collect,
};

const test_port: GenericMediaRuntimePort(MediaCapture) = .{
    .start = MediaCapture.start,
    .enforce_quotas = MediaCapture.enforceQuotas,
    .synchronize_clients = MediaCapture.synchronizeClients,
    .schedule_response = MediaCapture.scheduleResponse,
    .pump_clients = MediaCapture.pumpClients,
    .collect = MediaCapture.collect,
};

const TestCoordinator = GenericMediaCoordinator(MediaCapture, test_port);

fn testCoordinator(capture: *MediaCapture, panes: *PaneStore, metrics: *RuntimeMetrics) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .panes = panes,
        .metrics = metrics,
    });
}

fn beginFixtureMedia(fixture: *PaneFixtureType, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    fixture.pane.queueMediaOutput("media");
    try std.testing.expect(fixture.pane.beginMediaProcessing() != null);
}

fn queueFollowUp(fixture: *PaneFixtureType) void {
    fixture.pane.queueMediaOutput("follow-up");
}

fn expectSteps(capture: *const MediaCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectMetrics(metrics: *const RuntimeMetrics, expected: MediaExpectedMetrics) !void {
    const actual = if (comptime enabled_module) expected else MediaExpectedMetrics{};
    try std.testing.expectEqual(actual.output_bytes, metrics.media_bytes);
    try std.testing.expectEqual(actual.discarded, metrics.media_discarded_frames);
    try std.testing.expectEqual(actual.unavailable, metrics.media_unavailable_frames);
    try std.testing.expectEqual(actual.forwarded, metrics.media_forwarded_frames);
    try std.testing.expectEqual(actual.failures, metrics.media_failures);
    try std.testing.expectEqual(actual.resets, metrics.media_resets);
    try std.testing.expectEqual(actual.staged, metrics.graphics_transfers_staged);
}

test "media completion refreshes graphics before clients and preserves effect order" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    fixture.pane.graphics_revision = std.math.maxInt(u64);
    try fixture.addRgbaImage(7);
    var capture: MediaCapture = .{ .projection = .{ .staged = 2 } };
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: MediaCapture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{ .pane = fixture.pane.key(), .stats = .{} });

    try expectSteps(&capture, &.{ .quotas, .synchronize_clients, .response, .pump_clients, .media, .collect, .pump_clients });
    try std.testing.expect(capture.start_saw_borrow);
    try std.testing.expectEqualDeep(fixture.pane.size, capture.started_work.?.current_size);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.actor_count);
    fixture.pane.cancelMediaProcessing();
}

test "response scheduling failure stops before pumping and media rearm" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    fixture.pane.graphics_present = true;
    queueFollowUp(&fixture);
    var capture: MediaCapture = .{ .response_failure = true };
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try beginFixtureMedia(&fixture, &panes);
    queueFollowUp(&fixture);
    var capture: MediaCapture = .{ .start_failure = true };
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
    var capture: MediaCapture = .{};
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
