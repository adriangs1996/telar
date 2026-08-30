//! Interactive pipeline for one completed PTY output read.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../pane/root.zig");
const telemetry_mod = @import("telemetry.zig");
const test_support = @import("test_support.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Completion = struct {
    pane: PaneKey,
    result: anyerror!u16,
};

/// Output-buffer borrow handed to the VT ingest actor.
pub const Ingest = struct {
    io: Io,
    pane: *Pane,
    bytes: []const u8,
};

pub const Resources = struct {
    io: Io,
    panes: *PaneStore,
    metrics: *RuntimeMetrics,
};

/// Defines the schedulers, client-state query, and lifecycle effects supplied
/// by the runtime composition root.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        schedule_observation: *const fn (*Context, *Pane) anyerror!void,
        schedule_media: *const fn (*Context, *Pane) anyerror!void,
        start_ingest: *const fn (*Context, Ingest) anyerror!void,
        has_outstanding_frame: *const fn (*Context, schema.PaneId) bool,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched PTY output pipeline.
///
/// ```zig
/// const OutputPipeline = Pipeline(Context, port);
/// ```
pub fn Pipeline(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds one runtime's pane repository and telemetry.
        ///
        /// ```zig
        /// var pipeline = OutputPipeline.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Completes one read. EOF/error settles the output lifecycle; data is
        /// copied into observation/media queues before its buffer is borrowed
        /// by the VT ingest actor. Scheduler errors cross unchanged.
        ///
        /// ```zig
        /// try pipeline.handle(completion);
        /// ```
        pub fn handle(pipeline: *Self, completion: Completion) !void {
            const pane = pipeline.resources.panes.resolve(completion.pane) orelse {
                pipeline.resources.metrics.stale_pane_events += 1;
                return;
            };
            const output_len = completion.result catch {
                pane.completePtyOutputRead(.finished);
                return pipeline.finishOutput(pane);
            };

            if (output_len == 0) {
                pane.completePtyOutputRead(.finished);
                return pipeline.finishOutput(pane);
            }

            pane.completePtyOutputRead(.data);

            if (comptime diagnostics.enabled) {
                pipeline.resources.metrics.pty_events += 1;
                pipeline.resources.metrics.pty_bytes += output_len;

                if (port.has_outstanding_frame(pipeline.context, pane.id)) {
                    pipeline.resources.metrics.folded_pty_events += 1;
                }
            }

            const bytes = pane.output_buffer[0..output_len];
            pane.queueHistoryOutput(.{
                .bytes = bytes,
                .shell_foreground = pane.session.shellForeground(),
                .clock = pane_mod.historyClock(pipeline.resources.io),
            });
            try port.schedule_observation(pipeline.context, pane);

            pane.queueMediaOutput(bytes);
            try port.schedule_media(pipeline.context, pane);

            const ingest: Ingest = .{
                .io = pipeline.resources.io,
                .pane = pane,
                .bytes = pane.beginOutputIngest(output_len),
            };
            port.start_ingest(pipeline.context, ingest) catch |err| {
                pane.cancelOutputIngest();
                return err;
            };
        }

        fn finishOutput(pipeline: *Self, pane: *Pane) !void {
            if (pane.exit) |exit| {
                pane.queueExitedHistory(exit);
                try port.schedule_observation(pipeline.context, pane);
            }

            port.collect(pipeline.context);
            port.pump_clients(pipeline.context);
        }
    };
}

const Step = enum {
    observation,
    media,
    ingest,
    collect,
    pump_clients,
};

const Capture = struct {
    steps: [5]Step = undefined,
    len: usize = 0,
    failure: ?Step = null,
    outstanding_frame: bool = false,
    outstanding_frame_queries: usize = 0,
    observation_saw_history: bool = false,
    media_saw_output: bool = false,
    ingest_saw_borrow: bool = false,
    ingest_bytes: []const u8 = "",

    fn record(capture: *Capture, step: Step) !void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;

        if (capture.failure == step) {
            return error.SchedulerUnavailable;
        }
    }

    fn scheduleObservation(capture: *Capture, pane: *Pane) !void {
        capture.observation_saw_history = pane.history_observer.hasPending();
        try capture.record(.observation);
    }

    fn scheduleMedia(capture: *Capture, pane: *Pane) !void {
        capture.media_saw_output = pane.media.hasPending();
        try capture.record(.media);
    }

    fn startIngest(capture: *Capture, ingest: Ingest) !void {
        capture.ingest_saw_borrow = ingest.pane.ingest_pending;
        capture.ingest_bytes = ingest.bytes;
        try capture.record(.ingest);
    }

    fn hasOutstandingFrame(capture: *Capture, _: schema.PaneId) bool {
        capture.outstanding_frame_queries += 1;
        return capture.outstanding_frame;
    }

    fn collect(capture: *Capture) void {
        capture.record(.collect) catch unreachable;
    }

    fn pumpClients(capture: *Capture) void {
        capture.record(.pump_clients) catch unreachable;
    }
};

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

const ExpectedPtyMetrics = struct {
    events: u64,
    bytes: u64,
    folded: u64,
};

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
