//! Ownership of one bidirectional HTTP/2 relay.

const std = @import("std");
const relay = @import("relay.zig");

pub const Settings = struct {
    child: relay.PeerSettings = .{},
    origin: relay.PeerSettings = .{},
};

/// Supplies both directional relays and the effects produced when they stop.
///
/// ```zig
/// const port: ConnectionPort(Context) = .{
///     .io = Context.io,
///     .relay_request = Context.relayRequest,
///     .relay_response = Context.relayResponse,
///     .record_decode_failure = Context.recordDecodeFailure,
///     .settle = Context.settle,
/// };
/// ```
pub fn ConnectionPort(comptime Context: type) type {
    return struct {
        io: *const fn (*Context) std.Io,
        relay_request: *const fn (*Context, *Settings) relay.Stats,
        relay_response: *const fn (*Context, *Settings) relay.Stats,
        record_decode_failure: *const fn (*Context, relay.Direction) void,
        settle: *const fn (*Context) void,
    };
}

/// Creates the lifecycle owner for one intercepted HTTP/2 connection.
///
/// ```zig
/// const RelayConnection = Connection(Context, connection_port);
/// RelayConnection.run(&context);
/// ```
pub fn Connection(comptime Context: type, comptime port: ConnectionPort(Context)) type {
    return struct {
        /// Relays requests concurrently while the response direction owns the
        /// connection lifetime. Once responses end, it cancels the request
        /// relay, records each failed decoder, then settles all open streams.
        ///
        /// ```zig
        /// RelayConnection.run(&context);
        /// ```
        pub fn run(context: *Context) void {
            var settings: Settings = .{};
            const io = port.io(context);
            var request = io.concurrent(relayRequest, .{ context, &settings }) catch {
                port.settle(context);
                return;
            };
            const response_stats = port.relay_response(context, &settings);
            const request_stats = request.cancel(io);

            if (response_stats.decode_failed) {
                port.record_decode_failure(context, .response);
            }

            if (request_stats.decode_failed) {
                port.record_decode_failure(context, .request);
            }

            port.settle(context);
        }

        fn relayRequest(context: *Context, settings: *Settings) relay.Stats {
            return port.relay_request(context, settings);
        }
    };
}

const Step = enum {
    response_decode_failure,
    request_decode_failure,
    settle,
};

const Capture = struct {
    request_started: ?*std.Io.Queue(u8) = null,
    request_release: ?*std.Io.Queue(u8) = null,
    request_canceled: std.atomic.Value(bool) = .init(false),
    response_saw_request: bool = false,
    response_saw_shared_settings: bool = false,
    request_stats: relay.Stats = .{},
    response_stats: relay.Stats = .{},
    steps: [3]Step = undefined,
    step_len: usize = 0,

    fn io(_: *Capture) std.Io {
        return std.testing.io;
    }

    fn relayRequest(capture: *Capture, settings: *Settings) relay.Stats {
        settings.child.max_frame_size.store(32 * 1024, .seq_cst);

        if (capture.request_started) |started| {
            started.putOneUncancelable(std.testing.io, 0) catch return capture.request_stats;
        }

        if (capture.request_release) |release| {
            _ = release.getOne(std.testing.io) catch {
                capture.request_canceled.store(true, .release);
            };
        }

        return capture.request_stats;
    }

    fn relayResponse(capture: *Capture, settings: *Settings) relay.Stats {
        if (capture.request_started) |started| {
            _ = started.getOne(std.testing.io) catch return capture.response_stats;
            capture.response_saw_request = true;
        }

        capture.response_saw_shared_settings = settings.child.max_frame_size.load(.seq_cst) == 32 * 1024;
        return capture.response_stats;
    }

    fn recordDecodeFailure(capture: *Capture, direction: relay.Direction) void {
        capture.record(switch (direction) {
            .request => .request_decode_failure,
            .response => .response_decode_failure,
        });
    }

    fn settle(capture: *Capture) void {
        capture.record(.settle);
    }

    fn record(capture: *Capture, step: Step) void {
        std.debug.assert(capture.step_len < capture.steps.len);
        capture.steps[capture.step_len] = step;
        capture.step_len += 1;
    }
};

const test_port: ConnectionPort(Capture) = .{
    .io = Capture.io,
    .relay_request = Capture.relayRequest,
    .relay_response = Capture.relayResponse,
    .record_decode_failure = Capture.recordDecodeFailure,
    .settle = Capture.settle,
};

const TestConnection = Connection(Capture, test_port);

test "response completion cancels the unfinished request relay before settlement" {
    var started_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var release: std.Io.Queue(u8) = .init(&release_storage);
    var capture: Capture = .{
        .request_started = &started,
        .request_release = &release,
    };

    TestConnection.run(&capture);

    try std.testing.expect(capture.response_saw_request);
    try std.testing.expect(capture.response_saw_shared_settings);
    try std.testing.expect(capture.request_canceled.load(.acquire));
    try std.testing.expectEqualSlices(Step, &.{.settle}, capture.steps[0..capture.step_len]);
}

test "both decode failures are recorded before connection settlement" {
    var started_storage: [1]u8 = undefined;
    var started: std.Io.Queue(u8) = .init(&started_storage);
    var capture: Capture = .{
        .request_started = &started,
        .request_stats = .{ .decode_failed = true },
        .response_stats = .{ .decode_failed = true },
    };

    TestConnection.run(&capture);

    try std.testing.expectEqualSlices(
        Step,
        &.{ .response_decode_failure, .request_decode_failure, .settle },
        capture.steps[0..capture.step_len],
    );
}
