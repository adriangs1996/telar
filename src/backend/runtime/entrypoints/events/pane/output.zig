//! Interactive pipeline for one completed PTY output read.

const GenericOutputRuntimePort = @import("GenericOutputRuntimePort.zig").Type;
const OutputCapture = @import("OutputCapture.zig");
const GenericPipeline = @import("GenericPipeline.zig").Type;
const PaneStore = @import("../../../../pane/PaneStore.zig");
const RuntimeMetrics = @import("../../../observability/RuntimeMetrics.zig");
const std = @import("std");
const PaneFixtureType = @import("../../../tests/PaneFixture.zig");
const ExpectedPtyMetrics = @import("ExpectedPtyMetrics.zig");
const enabled_module = @import("telar-core").enabled;
const PaneProgressStateType = @import("telar-core").PaneProgressState;
const Pane = @import("../../../../pane/Pane.zig");

pub const Step = enum {
    observation,
    media,
    ingest,
    collect,
    pump_clients,
};

const test_port: GenericOutputRuntimePort(OutputCapture) = .{
    .schedule_observation = OutputCapture.scheduleObservation,
    .schedule_media = OutputCapture.scheduleMedia,
    .start_ingest = OutputCapture.startIngest,
    .has_outstanding_frame = OutputCapture.hasOutstandingFrame,
    .collect = OutputCapture.collect,
    .pump_clients = OutputCapture.pumpClients,
};

const TestPipeline = GenericPipeline(OutputCapture, test_port);

fn testPipeline(capture: *OutputCapture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPipeline {
    return TestPipeline.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn insertFixturePane(fixture: *PaneFixtureType, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    try std.testing.expect(fixture.pane.beginPtyOutputRead());
}

fn expectPtyMetrics(metrics: *const RuntimeMetrics, expected: ExpectedPtyMetrics) !void {
    const expected_events = if (comptime enabled_module) expected.events else 0;
    const expected_bytes = if (comptime enabled_module) expected.bytes else 0;
    const expected_folded = if (comptime enabled_module) expected.folded else 0;
    try std.testing.expectEqual(expected_events, metrics.pty_events);
    try std.testing.expectEqual(expected_bytes, metrics.pty_bytes);
    try std.testing.expectEqual(expected_folded, metrics.folded_pty_events);
}

test "read error finishes output before collection and client pumping" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: OutputCapture = .{};
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = error.BrokenPipe,
    });

    try std.testing.expectEqualSlices(Step, &.{ .collect, .pump_clients }, capture.steps[0..capture.len]);
    try std.testing.expect(fixture.pane.output_done);
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expect(!fixture.pane.beginPtyOutputRead());
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
    try expectPtyMetrics(&fixture.metrics, .{ .events = 0, .bytes = 0, .folded = 0 });
}

test "EOF after exit queues the exit observation before lifecycle effects" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.exit = .{ .exited = 7 };
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: OutputCapture = .{};
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 0,
    });

    try std.testing.expectEqualSlices(Step, &.{ .observation, .collect, .pump_clients }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(fixture.pane.history_exit_queued);
    try std.testing.expect(fixture.pane.output_done);
}

test "data fans out before the VT ingest actor borrows the output buffer" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    @memcpy(fixture.pane.output_buffer[0..6], "output");
    var capture: OutputCapture = .{ .outstanding_frame = true };
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 6,
    });

    try std.testing.expectEqualSlices(Step, &.{ .observation, .media, .ingest }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(capture.media_saw_output);
    try std.testing.expect(capture.ingest_saw_borrow);
    try std.testing.expectEqualStrings("output", capture.ingest_bytes);
    const expected_queries: usize = if (comptime enabled_module) 1 else 0;
    try std.testing.expectEqual(expected_queries, capture.outstanding_frame_queries);
    try expectPtyMetrics(&fixture.metrics, .{ .events = 1, .bytes = 6, .folded = 1 });
    try std.testing.expect(!fixture.pane.output_pending);
    try std.testing.expect(!fixture.pane.output_done);
    try std.testing.expect(fixture.pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 1), fixture.pane.actor_count);
    try std.testing.expect(!fixture.pane.beginPtyOutputRead());
    fixture.pane.cancelOutputIngest();
}

test "data read while the shell owns the terminal expires stale progress" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b]9;4;1;42\x1b\\");
    try std.testing.expectEqual(PaneProgressStateType.set, fixture.pane.progress_state);
    fixture.pane.output_buffer[0] = 'x';
    var capture: OutputCapture = .{};
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 1,
    });

    try std.testing.expectEqual(PaneProgressStateType.remove, fixture.pane.progress_state);
    try std.testing.expectEqual(@as(?u8, null), fixture.pane.progress_percent);
    fixture.pane.cancelOutputIngest();
}

test "observation scheduling failure stops before media and ingest" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: OutputCapture = .{ .failure = .observation };
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 1,
    }));

    try std.testing.expectEqualSlices(Step, &.{.observation}, capture.steps[0..capture.len]);
    try std.testing.expect(capture.observation_saw_history);
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "media scheduling failure stops before ingest" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: OutputCapture = .{ .failure = .media };
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 1,
    }));

    try std.testing.expectEqualSlices(Step, &.{ .observation, .media }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.media_saw_output);
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "ingest start failure releases its buffer borrow" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: OutputCapture = .{ .failure = .ingest };
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 1,
    }));

    try std.testing.expectEqualSlices(Step, &.{ .observation, .media, .ingest }, capture.steps[0..capture.len]);
    try std.testing.expect(capture.ingest_saw_borrow);
    try std.testing.expect(!fixture.pane.ingest_pending);
    try std.testing.expectEqual(@as(u8, 0), fixture.pane.actor_count);
}

test "exit observation failure skips collection and client pumping" {
    var fixture: PaneFixtureType = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.exit = .{ .exited = 7 };
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: OutputCapture = .{ .failure = .observation };
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try std.testing.expectError(error.SchedulerUnavailable, pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 0,
    }));

    try std.testing.expectEqualSlices(Step, &.{.observation}, capture.steps[0..capture.len]);
    try std.testing.expect(fixture.pane.output_done);
    try std.testing.expect(fixture.pane.history_exit_queued);
}

test "stale generation cannot release a live output-read borrow" {
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.output_pending = true;
    pane.output_done = false;
    pane.actor_count = 1;
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: OutputCapture = .{};
    var pipeline = testPipeline(&capture, &panes, &metrics);

    try pipeline.handle(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = 1,
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try std.testing.expect(pane.output_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyOutputRead();
}
