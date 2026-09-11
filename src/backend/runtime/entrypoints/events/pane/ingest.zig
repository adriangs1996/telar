//! Post-ingest coordination for one pane generation.

const GenericIngestRuntimePort = @import("GenericIngestRuntimePort.zig").Type;
const IngestCapture = @import("IngestCapture.zig");
const GenericIngestCoordinator = @import("GenericIngestCoordinator.zig").Type;
const PaneStore = @import("../../../../pane/PaneStore.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const std = @import("std");
const PaneFixtureType = @import("../../../tests/PaneFixture.zig");
const enabled_module = @import("telar-core").enabled;
const TerminalSizeType = @import("telar-core").TerminalSize;
const Pane = @import("../../../../pane/Pane.zig");

pub const Step = enum {
    observation,
    media,
    refresh_clients,
    response,
    read,
    collect,
    pump_clients,
};

const test_port: GenericIngestRuntimePort(IngestCapture) = .{
    .schedule_observation = IngestCapture.scheduleObservation,
    .schedule_media = IngestCapture.scheduleMedia,
    .refresh_clients = IngestCapture.refreshClients,
    .schedule_response = IngestCapture.scheduleResponse,
    .start_read = IngestCapture.startRead,
    .collect = IngestCapture.collect,
    .pump_clients = IngestCapture.pumpClients,
};

const TestCoordinator = GenericIngestCoordinator(IngestCapture, test_port);

fn testCoordinator(capture: *IngestCapture, panes: *PaneStore, metrics: *RuntimeMetrics) TestCoordinator {
    return TestCoordinator.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn insertFixturePane(fixture: *PaneFixtureType, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    _ = fixture.pane.beginOutputIngest(1);
}

fn expectSteps(capture: *const IngestCapture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

fn expectIngestTiming(metrics: *const RuntimeMetrics, elapsed_ns: u64) !void {
    const expected_count: u64 = if (comptime enabled_module) 1 else 0;
    const expected_elapsed: u64 = if (comptime enabled_module) elapsed_ns else 0;
    try std.testing.expectEqual(expected_count, metrics.ingest.count);
    try std.testing.expectEqual(expected_elapsed, metrics.ingest.total_ns);
    try std.testing.expectEqual(expected_elapsed, metrics.ingest.max_ns);
}

test "ingest failure closes the pane output before collection" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{};
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{};
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
    const resized: TerminalSizeType = .{ .cols = 30, .rows = 8 };
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.requestResize(resized);
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{ .expected_size = resized };
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
    const resized: TerminalSizeType = .{ .cols = 30, .rows = 8 };
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    try fixture.pane.requestResize(resized);
    fixture.failNextPaneAllocation();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{};
    var coordinator = testCoordinator(&capture, &panes, &fixture.metrics);

    try coordinator.handle(.{
        .pane = fixture.pane.key(),
        .result = .{ .elapsed_ns = 1 },
    });

    try expectSteps(&capture, &.{ .observation, .media, .refresh_clients, .response, .read, .collect, .pump_clients });
    try std.testing.expect(fixture.pane.close_requested);
    try std.testing.expectEqualDeep(PaneFixtureType.initial_size, fixture.pane.size);
    try std.testing.expectEqualDeep(resized, fixture.pane.pending_size.?);
    fixture.pane.cancelPtyOutputRead();
}

test "observation failure stops every later post-ingest effect" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{ .failure = .observation };
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{ .failure = .media };
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{ .failure = .response };
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
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: IngestCapture = .{ .failure = .read };
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
    pane.pending_terminal_colors = null;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: IngestCapture = .{};
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
