//! State machine for asynchronous terminal-emulator responses to a pane PTY.

const std = @import("std");
const pane_mod = @import("../../pane/root.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const Io = std.Io;
const Pane = pane_mod.Pane;
const PaneKey = pane_mod.PaneKey;
const PaneStore = pane_mod.PaneStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Completion = struct {
    pane: PaneKey,
    result: anyerror!void,
};

/// Stable response borrowed from the queue until completion is handled.
pub const Write = struct {
    io: Io,
    pane: *Pane,
    bytes: []const u8,
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

/// Creates a statically dispatched PTY response pump.
///
/// ```zig
/// const ResponsePump = Pump(Context, port);
/// ```
pub fn Pump(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Binds the pane repository and runtime telemetry.
        ///
        /// ```zig
        /// var pump = ResponsePump.init(&context, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Starts at most one response write. Async-start failure releases the
        /// actor borrow while preserving the queue head for a retry.
        ///
        /// ```zig
        /// try pump.schedule(pane);
        /// ```
        pub fn schedule(pump: *Self, pane: *Pane) !void {
            const bytes = pane.beginPtyResponseWrite() orelse return;
            const write: Write = .{
                .io = pump.resources.io,
                .pane = pane,
                .bytes = bytes,
            };

            port.start(pump.context, write) catch |err| {
                pane.cancelPtyResponseWrite();
                return err;
            };
        }

        /// Applies one generation-matched completion. Success removes the
        /// written head and starts the next response; PTY failure clears the
        /// queue. Collection runs only after the pump reaches a settled state.
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

            pane.completePtyResponseWrite(result);

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
    pane.pty_responses = .{};
    pane.response_pending = false;
    pane.actor_count = 0;
}

fn testPump(capture: *Capture, panes: *PaneStore, metrics: *RuntimeMetrics) TestPump {
    return TestPump.init(capture, .{
        .io = std.testing.io,
        .panes = panes,
        .metrics = metrics,
    });
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
    try std.testing.expect(pane.pty_responses.push("queued"));
    try std.testing.expectError(error.WriterUnavailable, pump.schedule(&pane));

    try std.testing.expectEqualStrings("queued", pane.pty_responses.peek().?);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);

    capture.start_failure = null;
    try pump.schedule(&pane);
    try pump.schedule(&pane);

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqualStrings("queued", capture.last_bytes);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyResponseWrite();
}

test "successful completion removes one response and starts the next" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .result = {},
    });

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expectEqualStrings("second", capture.last_bytes);
    try std.testing.expectEqualStrings("second", pane.pty_responses.peek().?);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqual(@as(u8, 1), pane.actor_count);
    pane.cancelPtyResponseWrite();
}

test "failed completion clears queued responses without another write" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));

    try pump.complete(.{
        .pane = pane.key(),
        .result = error.BrokenPipe,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.starts);
    try std.testing.expectEqual(@as(usize, 1), capture.collects);
    try std.testing.expect(pane.pty_responses.peek() == null);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "next-response start failure preserves the head and skips collection" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("first"));
    try pump.schedule(&pane);
    try std.testing.expect(pane.pty_responses.push("second"));
    capture.start_failure = error.WriterUnavailable;

    try std.testing.expectError(error.WriterUnavailable, pump.complete(.{
        .pane = pane.key(),
        .result = {},
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expectEqualStrings("second", pane.pty_responses.peek().?);
    try std.testing.expect(!pane.response_pending);
    try std.testing.expectEqual(@as(u8, 0), pane.actor_count);
}

test "stale generation cannot release a live response borrow" {
    var pane: Pane = undefined;
    initTestPane(&pane);
    var panes: PaneStore = .{};
    try panes.insert(&pane);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var capture: Capture = .{};
    var pump = testPump(&capture, &panes, &metrics);
    try std.testing.expect(pane.pty_responses.push("still borrowed"));
    _ = pane.beginPtyResponseWrite().?;

    try pump.complete(.{
        .pane = .{ .id = pane.id, .generation = pane.generation + 1 },
        .result = {},
    });

    try std.testing.expectEqual(@as(u64, 1), metrics.stale_pane_events);
    try std.testing.expectEqual(@as(usize, 0), capture.starts);
    try std.testing.expectEqual(@as(usize, 0), capture.collects);
    try std.testing.expect(pane.response_pending);
    try std.testing.expectEqualStrings("still borrowed", pane.pty_responses.peek().?);
    pane.cancelPtyResponseWrite();
}
