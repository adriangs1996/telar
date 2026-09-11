//! Interactive pipeline for one completed PTY output read.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../../pane/root.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;
const test_support = @import("../../../tests/support.zig");

pub const Io = std.Io;
pub const diagnostics = core.diagnostics;
pub const schema = core.schema;
pub const Pane = pane_mod.Pane;
pub const PaneKey = pane_mod.PaneKey;
pub const PaneStore = pane_mod.PaneStore;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Completion = @import("OutputCompletion.zig");

pub const Ingest = @import("OutputIngest.zig");

pub const Resources = @import("OutputResources.zig");

pub const RuntimePort = @import("GenericOutputRuntimePort.zig").Type;

pub const Pipeline = @import("GenericPipeline.zig").Type;

pub const Step = enum {
    observation,
    media,
    ingest,
    collect,
    pump_clients,
};

const Capture = @import("OutputCapture.zig");

const test_port: RuntimePort(Capture) = .{
    .schedule_observation = Capture.scheduleObservation,
    .schedule_media = Capture.scheduleMedia,
    .start_ingest = Capture.startIngest,
    .has_outstanding_frame = Capture.hasOutstandingFrame,
    .collect = Capture.collect,
    .pump_clients = Capture.pumpClients,
};

const TestPipeline = Pipeline(Capture, test_port);

fn testPipeline(capture: *Capture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPipeline {
    return TestPipeline.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn insertFixturePane(fixture: *test_support.PaneFixture, panes: *PaneStore) !void {
    try panes.insert(fixture.pane);
    try std.testing.expect(fixture.pane.beginPtyOutputRead());
}

const ExpectedPtyMetrics = @import("ExpectedPtyMetrics.zig");

fn expectPtyMetrics(metrics: *const RuntimeMetrics, expected: ExpectedPtyMetrics) !void {
    const expected_events = if (comptime diagnostics.enabled) expected.events else 0;
    const expected_bytes = if (comptime diagnostics.enabled) expected.bytes else 0;
    const expected_folded = if (comptime diagnostics.enabled) expected.folded else 0;
    try std.testing.expectEqual(expected_events, metrics.pty_events);
    try std.testing.expectEqual(expected_bytes, metrics.pty_bytes);
    try std.testing.expectEqual(expected_folded, metrics.folded_pty_events);
}

test "read error finishes output before collection and client pumping" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{};
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.exit = .{ .exited = 7 };
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{};
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    @memcpy(fixture.pane.output_buffer[0..6], "output");
    var capture: Capture = .{ .outstanding_frame = true };
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
    const expected_queries: usize = if (comptime diagnostics.enabled) 1 else 0;
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    _ = try fixture.pane.ingest(std.testing.io, "\x1b]9;4;1;42\x1b\\");
    try std.testing.expectEqual(schema.PaneProgressState.set, fixture.pane.progress_state);
    fixture.pane.output_buffer[0] = 'x';
    var capture: Capture = .{};
    var pipeline = testPipeline(&capture, &panes, &fixture.metrics);

    try pipeline.handle(.{
        .pane = fixture.pane.key(),
        .result = 1,
    });

    try std.testing.expectEqual(schema.PaneProgressState.remove, fixture.pane.progress_state);
    try std.testing.expectEqual(@as(?u8, null), fixture.pane.progress_percent);
    fixture.pane.cancelOutputIngest();
}

test "observation scheduling failure stops before media and ingest" {
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: Capture = .{ .failure = .observation };
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: Capture = .{ .failure = .media };
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    fixture.pane.output_buffer[0] = 'x';
    var capture: Capture = .{ .failure = .ingest };
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
    var fixture: test_support.PaneFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    fixture.pane.exit = .{ .exited = 7 };
    var panes: PaneStore = .{};
    try insertFixturePane(&fixture, &panes);
    var capture: Capture = .{ .failure = .observation };
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
    var capture: Capture = .{};
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
