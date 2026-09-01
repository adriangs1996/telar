//! State machine for asynchronous writes from a pane's bounded input queue.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../../pane/root.zig");
const telemetry_mod = @import("../../../observability/root.zig").telemetry;

const Io = std.Io;
const diagnostics = core.diagnostics;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Completion = struct {
    pane: PaneKey,
    started_ns: u64,
    result: anyerror!void,
};

/// Stable input borrowed from a pane until its completion event is handled.
pub const Write = struct {
    io: Io,
    pane: *Pane,
    bytes: []const u8,
    started_ns: u64,
};

pub const Resources = struct {
    io: Io,
    panes: *PaneStore,
    metrics: *RuntimeMetrics,
};

/// Defines the async writer and lifecycle effects supplied by the runtime.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ .start = start, .collect = collect };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Write) anyerror!void,
        collect: *const fn (*Context) void,
    };
}

/// Creates a statically dispatched input pump for one runtime context.
///
/// ```zig
/// const InputPump = Pump(Context, port);
/// ```
pub fn Pump(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds the pane repository and telemetry owned by one runtime.
        ///
        /// ```zig
        /// var pump = InputPump.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one write for the pane. Async-start failure rolls
        /// back the borrow and preserves every queued byte for a later retry.
        ///
        /// ```zig
        /// try pump.schedule(pane);
        /// ```
        pub fn schedule(pump: *Self, pane: *Pane) !void {
            const bytes = pane.beginPtyInputWrite() orelse return;
            const write: Write = .{
                .io = pump.resources.io,
                .pane = pane,
                .bytes = bytes,
                .started_ns = if (comptime diagnostics.enabled) diagnostics.now(pump.resources.io) else 0,
            };

            port.start(pump.context, write) catch |err| {
                pane.cancelPtyInputWrite();
                return err;
            };
        }

        /// Applies exactly one completion to its generation-matched pane.
        /// Success consumes the borrowed prefix and schedules the backlog;
        /// PTY failure clears the queue. Collection runs after a settled pump.
        ///
        /// ```zig
        /// try pump.complete(completion);
        /// ```
        pub fn complete(pump: *Self, completion: Completion) !void {
            const pane = pump.resources.panes.resolve(completion.pane) orelse {
                pump.resources.metrics.stale_pane_events += 1;
                return;
            };

            const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

            pane.completePtyInputWrite(result);

            if (comptime diagnostics.enabled) {
                pump.resources.metrics.input_write.observe(
                    diagnostics.elapsed(completion.started_ns, diagnostics.now(pump.resources.io)),
                );
            }

            if (result == .succeeded) {
                try pump.schedule(pane);
            }

            port.collect(pump.context);
        }
    };
}

const Capture = struct {
    starts: usize = 0,
    collects: usize = 0,
    start_failure: ?anyerror = null,
    last_bytes: []const u8 = "",

    fn start(capture: *Capture, write: Write) !void {
        capture.starts += 1;
        capture.last_bytes = write.bytes;

        if (capture.start_failure) |failure| {
            return failure;
        }
    }

    fn collect(capture: *Capture) void {
        capture.collects += 1;
    }
};

const test_port: RuntimePort(Capture) = .{
    .start = Capture.start,
    .collect = Capture.collect,
};

const TestPump = Pump(Capture, test_port);

fn initTestPane(pane: *Pane) void {
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    pane.input_queue = .{};
    pane.input_write_pending = false;
    pane.input_write_len = 0;
    pane.actor_count = 0;
}

fn testPump(capture: *Capture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPump {
    return TestPump.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
}

fn expectInputTiming(metrics: *const RuntimeMetrics, expected_debug_count: u64) !void {
    const expected = if (comptime diagnostics.enabled) expected_debug_count else 0;
    try std.testing.expectEqual(expected, metrics.input_write.count);
}

test "schedule is single-flight and rolls async-start failure back" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{ .start_failure = error.WriterUnavailable };
    var pump = testPump(&capture, &panes, &metrics);

    try pump.schedule(&pane);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expect(pane.queuePtyInput("queued"));
    try std.testing.expectError(error.WriterUnavailable, pump.schedule(&pane));

    try std.testing.expectEqualStrings("queued", pane.input_queue.nextChunk().?);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(usize, 0), pane.input_write_len);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);

    capture.start_failure = null;
    try pump.schedule(&pane);
    try pump.schedule(&pane);

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqualStrings("queued", capture.last_bytes);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyInputWrite();
}

test "successful completion consumes only its borrow and starts the backlog" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = {},
    });

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expectEqualStrings("second", capture.last_bytes);
    try std.testing.expectEqualStrings("second", pane.input_queue.nextChunk().?);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqual(@as(usize, "second".len), pane.input_write_len);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    try expectInputTiming(&metrics, 1);
    pane.cancelPtyInputWrite();
}

test "failed completion clears the pump without starting another write" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = error.BrokenPipe,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expect(pane.input_queue.nextChunk() == null);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try expectInputTiming(&metrics, 1);
}

test "backlog start failure preserves bytes and skips collection" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.queuePtyInput("second"));
    capture.start_failure = error.WriterUnavailable;

    try std.testing.expectError(error.WriterUnavailable, pump.complete(.{
        .pane = pane.key(),
        .started_ns = 0,
        .result = {},
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expectEqualStrings("second", pane.input_queue.nextChunk().?);
    try std.testing.expect(!pane.input_write_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
    try expectInputTiming(&metrics, 1);
}

test "stale completion is counted without touching writer or lifecycle ports" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.queuePtyInput("still borrowed"));
    _ = pane.beginPtyInputWrite().?;

    try pump.complete(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .started_ns = 0,
        .result = {},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try expectInputTiming(&metrics, 0);
    try std.testing.expect(pane.input_write_pending);
    try std.testing.expectEqualStrings("still borrowed", pane.input_queue.nextChunk().?);
    pane.cancelPtyInputWrite();
}
