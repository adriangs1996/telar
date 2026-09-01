//! Bounded ownership transfer for accepted proxy connections.

const std = @import("std");

const Io = std.Io;

pub const SlotSnapshot = struct {
    active: u32,
    limit_drops: u64,
};

/// Owns the exact number of admitted connection workers and the number of
/// sockets rejected at the configured bound.
pub const Slots = struct {
    limit: u32,
    active: std.atomic.Value(u32) = .init(0),
    limit_drops: std.atomic.Value(u64) = .init(0),

    /// Creates an empty connection-slot counter with a fixed upper bound.
    ///
    /// ```zig
    /// var slots = Slots.init(64);
    /// ```
    pub fn init(limit: u32) Slots {
        return .{ .limit = limit };
    }

    /// Acquires one slot without allowing the observable count to exceed its
    /// bound. Rejection records one limit drop.
    ///
    /// ```zig
    /// if (!slots.acquire()) {
    ///     closeRejectedConnection();
    /// }
    /// ```
    pub fn acquire(slots: *Slots) bool {
        var current = slots.active.load(.monotonic);

        while (current < slots.limit) {
            if (slots.active.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic)) |observed| {
                current = observed;
                continue;
            }

            return true;
        }

        _ = slots.limit_drops.fetchAdd(1, .monotonic);
        return false;
    }

    /// Releases the slot owned by one completed or unscheduled connection.
    ///
    /// ```zig
    /// slots.release();
    /// ```
    pub fn release(slots: *Slots) void {
        const previous = slots.active.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
    }

    /// Returns a lock-free metrics snapshot.
    ///
    /// ```zig
    /// const metrics = slots.snapshot();
    /// ```
    pub fn snapshot(slots: *const Slots) SlotSnapshot {
        return .{
            .active = slots.active.load(.monotonic),
            .limit_drops = slots.limit_drops.load(.monotonic),
        };
    }
};

/// Defines listener, worker-group, slot, and socket operations supplied by the
/// proxy service. A successful `start` transfers both the stream and its slot
/// to the worker; every other path leaves them with the admission runner.
///
/// ```zig
/// const port: Port(Context, Stream) = .{ ... };
/// ```
pub fn Port(comptime Context: type, comptime Stream: type) type {
    return struct {
        accept: *const fn (*Context) anyerror!Stream,
        acquire: *const fn (*Context) bool,
        start: *const fn (*Context, *Io.Group, Stream) anyerror!void,
        release: *const fn (*Context) void,
        close: *const fn (*Context, Stream) void,
        cancel: *const fn (*Context, *Io.Group) void,
    };
}

/// Creates the accept-loop policy for one proxy service.
///
/// ```zig
/// const Admission = Runner(Context, Stream, port);
/// try Admission.run(&context);
/// ```
pub fn Runner(comptime Context: type, comptime Stream: type, comptime port: Port(Context, Stream)) type {
    return struct {
        /// Accepts until cancellation or listener closure while preserving
        /// exact stream and slot ownership on capacity and scheduling failures.
        /// Transient accept failures are retried.
        ///
        /// ```zig
        /// try Admission.run(&context);
        /// ```
        pub fn run(context: *Context) anyerror!void {
            var workers: Io.Group = .init;
            defer port.cancel(context, &workers);

            while (true) {
                const stream = port.accept(context) catch |err| switch (err) {
                    error.Canceled => |canceled| return canceled,
                    error.SocketNotListening => return,
                    else => continue,
                };

                if (!port.acquire(context)) {
                    port.close(context, stream);
                    continue;
                }

                port.start(context, &workers, stream) catch {
                    port.release(context);
                    port.close(context, stream);
                };
            }
        }
    };
}

const Step = enum {
    accept,
    acquire,
    start,
    release,
    close,
    cancel,
};

const AcceptResult = union(enum) {
    stream: u8,
    transient_failure,
    listener_closed,
    canceled,
};

const Capture = struct {
    steps: [20]Step = undefined,
    len: usize = 0,
    accepts: [4]AcceptResult = undefined,
    accept_len: usize = 0,
    accept_index: usize = 0,
    slot_available: bool = true,
    start_fails: bool = false,
    started_stream: ?u8 = null,
    closed_stream: ?u8 = null,
    releases: usize = 0,

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.len < capture.steps.len);
        capture.steps[capture.len] = step;
        capture.len += 1;
    }

    fn accept(capture: *Capture) !u8 {
        capture.record(.accept);
        const result = if (capture.accept_index < capture.accept_len)
            capture.accepts[capture.accept_index]
        else
            .listener_closed;
        capture.accept_index += 1;

        return switch (result) {
            .stream => |stream| stream,
            .transient_failure => error.ConnectionAborted,
            .listener_closed => error.SocketNotListening,
            .canceled => error.Canceled,
        };
    }

    fn acquire(capture: *Capture) bool {
        capture.record(.acquire);
        return capture.slot_available;
    }

    fn start(capture: *Capture, _: *Io.Group, stream: u8) !void {
        capture.record(.start);

        if (capture.start_fails) {
            return error.ConcurrencyUnavailable;
        }

        capture.started_stream = stream;
    }

    fn release(capture: *Capture) void {
        capture.record(.release);
        capture.releases += 1;
    }

    fn close(capture: *Capture, stream: u8) void {
        capture.record(.close);
        capture.closed_stream = stream;
    }

    fn cancel(capture: *Capture, _: *Io.Group) void {
        capture.record(.cancel);
    }
};

const test_port: Port(Capture, u8) = .{
    .accept = Capture.accept,
    .acquire = Capture.acquire,
    .start = Capture.start,
    .release = Capture.release,
    .close = Capture.close,
    .cancel = Capture.cancel,
};

const TestRunner = Runner(Capture, u8, test_port);

fn fixture(results: []const AcceptResult) Capture {
    std.debug.assert(results.len <= 4);
    var capture: Capture = .{};
    @memcpy(capture.accepts[0..results.len], results);
    capture.accept_len = results.len;
    return capture;
}

fn expectSteps(capture: *const Capture, expected: []const Step) !void {
    try std.testing.expectEqualSlices(Step, expected, capture.steps[0..capture.len]);
}

test "connection slots never expose a count above their bound" {
    var slots = Slots.init(2);

    try std.testing.expect(slots.acquire());
    try std.testing.expect(slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    try std.testing.expect(slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    slots.release();
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 1 }, slots.snapshot());
}

test "a zero connection limit rejects and counts every attempt" {
    var slots = Slots.init(0);

    try std.testing.expect(!slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 2 }, slots.snapshot());
}

test "listener closure stops and cancels the worker group" {
    var capture = fixture(&.{.listener_closed});

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .cancel });
}

test "listener cancellation propagates after canceling workers" {
    var capture = fixture(&.{.canceled});

    try std.testing.expectError(error.Canceled, TestRunner.run(&capture));

    try expectSteps(&capture, &.{ .accept, .cancel });
}

test "transient accept failure retries without touching admission state" {
    var capture = fixture(&.{ .transient_failure, .{ .stream = 7 }, .listener_closed });

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .accept, .acquire, .start, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 7), capture.started_stream);
    try std.testing.expect(capture.closed_stream == null);
    try std.testing.expectEqual(@as(usize, 0), capture.releases);
}

test "capacity rejection closes the stream without starting a worker" {
    var capture = fixture(&.{ .{ .stream = 9 }, .listener_closed });
    capture.slot_available = false;

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .acquire, .close, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 9), capture.closed_stream);
    try std.testing.expect(capture.started_stream == null);
    try std.testing.expectEqual(@as(usize, 0), capture.releases);
}

test "worker scheduling failure releases the slot before closing the stream" {
    var capture = fixture(&.{ .{ .stream = 11 }, .listener_closed });
    capture.start_fails = true;

    try TestRunner.run(&capture);

    try expectSteps(&capture, &.{ .accept, .acquire, .start, .release, .close, .accept, .cancel });
    try std.testing.expectEqual(@as(?u8, 11), capture.closed_stream);
    try std.testing.expectEqual(@as(usize, 1), capture.releases);
}
