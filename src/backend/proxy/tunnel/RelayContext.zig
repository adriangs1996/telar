//! HTTP/2 for one intercepted CONNECT exchange: the generic relay drives
//! both directions and calls these methods, which install capture streams
//! for the exchange and count decode failures.
const core = @import("telar-core");
const owned = @import("../capture/owned.zig");
const httprelay = @import("httprelay");
const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const h2frames = @import("h2frames");
const Stats = httprelay.http2.Stats;
const CaptureStreams = @import("CaptureStreams.zig");
const EventObserver = @import("EventObserver.zig");
const StreamsInFlight = @import("StreamsInFlight.zig");
const h2 = httprelay.http2;
const relay_module = httprelay.http2;
const Counters = @import("../Counters.zig");
const Snapshot = @import("../Snapshot.zig");
const HeaderField = h2frames.HeaderField;
const Joiner = owned.Joiner;
const GenericConnection = httprelay.http2.GenericConnection;
const RelayContext = @This();

pub const header_block_limit = core.Limit.declare("proxy.h2.max_header_block_bytes", "bytes", h2.max_header_block_bytes);
pub const tracked_streams_limit = core.Limit.declare("proxy.h2.max_tracked_streams", "streams", h2frames.streams.max_tracked_streams);

const RelayConnection = GenericConnection(RelayContext);

io: std.Io,
gpa: std.mem.Allocator,
session: *Session,
exchange: *Exchange,
captures: ?*Producer = null,
/// Streams in flight, shared by both directions' observers.
streams: StreamsInFlight = .{},

/// Relays both directions until the response side ends, then settles.
///
/// ```zig
/// relay_context.run();
/// ```
pub fn run(self: *RelayContext) void {
    RelayConnection.run(self.io, self);
}

/// Relays the request direction through request capture.
///
/// ```zig
/// const stats = relay_context.relayRequest();
/// ```
pub fn relayRequest(self: *RelayContext) Stats {
    return self.relayDirection(.request);
}

/// Relays the response direction through response capture.
///
/// ```zig
/// const stats = relay_context.relayResponse();
/// ```
pub fn relayResponse(self: *RelayContext) Stats {
    return self.relayDirection(.response);
}

fn relayDirection(self: *RelayContext, direction: relay_module.Direction) Stats {
    var captures = if (self.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = self.exchange,
        .side = switch (direction) {
            .request => .request,
            .response => .response,
        },
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .captures = if (captures) |*streams| streams else null,
        .exchange = self.exchange,
        .streams = &self.streams,
    };

    return h2.relay(self.session, h2.relayOptions(direction, .{ .gpa = self.gpa }), &observer);
}

/// Counts a direction whose header decoding failed.
///
/// ```zig
/// relay_context.recordDecodeFailure(.request);
/// ```
pub fn recordDecodeFailure(self: *RelayContext, _: relay_module.Direction) void {
    self.exchange.record(.h2_decode_failure);
}

/// Counts the bounds that cut a direction's observation: a header block
/// past `max_header_block_bytes` and streams past the tracked streams.
///
/// ```zig
/// relay_context.recordLimits(.response, stats);
/// ```
pub fn recordLimits(self: *RelayContext, _: relay_module.Direction, stats: Stats) void {
    if (stats.header_block_too_large) {
        self.exchange.record(.h2_header_block_too_large);
    }

    for (0..stats.untracked_streams) |_| {
        self.exchange.record(.h2_stream_untracked);
    }
}

/// Nothing outlives the relay: capture halves end with their streams.
///
/// ```zig
/// relay_context.settle();
/// ```
pub fn settle(self: *RelayContext) void {
    _ = self;
}

test "decode failure increments only the HTTP2 counter" {
    var harness: H2TestHarness = .{};
    harness.init();
    var context: RelayContext = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .session = undefined,
        .exchange = &harness.exchange,
    };

    context.recordDecodeFailure(.request);

    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().h2_decode_failures);
}

test "HTTP2 capture keeps interleaved streams independent" {
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .enabled = true,
        .max_part_bytes = 512,
        .max_exchange_bytes = 1024,
        .max_total_bytes = 4096,
    });
    defer producer.close(std.testing.io);
    var harness: H2TestHarness = .{};
    harness.init();
    harness.exchange.host = try std.Io.net.HostName.init("example.test");
    var requests: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .request };
    defer requests.deinit();
    var responses: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .response };
    defer responses.deinit();
    var request_observer: EventObserver = .{ .captures = &requests };
    var response_observer: EventObserver = .{ .captures = &responses };
    const first_request_headers = [_]HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/first" },
    };
    const second_request_headers = [_]HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/second" },
    };
    const response_headers = [_]HeaderField{.{ .name = ":status", .value = "200" }};

    request_observer.emit(.{ .request_headers = .{ .stream_id = 1, .fields = &first_request_headers } });
    request_observer.emit(.{ .request_headers = .{ .stream_id = 3, .fields = &second_request_headers } });
    request_observer.emit(.{ .request_body = .{ .stream_id = 1, .bytes = "first-" } });
    request_observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = "second-" } });
    request_observer.emit(.{ .request_body = .{ .stream_id = 1, .bytes = "body" } });
    request_observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = "body" } });
    request_observer.emit(.{ .request_finished = .{ .stream_id = 3 } });
    request_observer.emit(.{ .request_finished = .{ .stream_id = 1 } });

    response_observer.emit(.{ .response_headers = .{ .stream_id = 3, .fields = &response_headers } });
    response_observer.emit(.{ .response_headers = .{ .stream_id = 1, .fields = &response_headers } });
    response_observer.emit(.{ .response_body = .{ .stream_id = 3, .status_code = 200, .sse_body = false, .bytes = "two" } });
    response_observer.emit(.{ .response_body = .{ .stream_id = 1, .status_code = 200, .sse_body = false, .bytes = "one" } });
    response_observer.emit(.{ .lifecycle = .{ .stage = .response_ended, .stream_id = 1, .status_code = 200 } });
    response_observer.emit(.{ .lifecycle = .{ .stage = .response_ended, .stream_id = 3, .status_code = 200 } });

    var joiner = Joiner.init(30_000);
    defer joiner.deinit();
    var completed: usize = 0;
    var saw_first = false;
    var saw_second = false;
    for (0..4) |_| {
        const half = try producer.receive(std.testing.io);
        switch (joiner.push(1, half)) {
            .pending => {},
            .complete => |value| {
                var exchange = value;
                defer exchange.deinit();
                completed += 1;
                const request = exchange.request.?;
                const response = exchange.response.?;
                if (request.key.stream_id == 1) {
                    saw_first = true;
                    try std.testing.expectEqualStrings("/first", request.target());
                    try std.testing.expectEqualStrings("first-body", request.body.bytes());
                    try std.testing.expectEqualStrings("one", response.body.bytes());
                } else {
                    saw_second = true;
                    try std.testing.expectEqualStrings("/second", request.target());
                    try std.testing.expectEqualStrings("second-body", request.body.bytes());
                    try std.testing.expectEqualStrings("two", response.body.bytes());
                }
            },
            .partial, .full => |value| {
                var exchange = value;
                exchange.deinit();
                return error.UnexpectedPartialCapture;
            },
        }
    }

    try std.testing.expectEqual(@as(usize, 2), completed);
    try std.testing.expect(saw_first);
    try std.testing.expect(saw_second);
}

const H2TestHarness = struct {
    counters: Counters = .{},
    exchange: Exchange = undefined,

    /// Builds the harness at its final address: the exchange borrows the counters.
    pub fn init(self: *H2TestHarness) void {
        self.exchange = .{
            .io = std.testing.io,
            .telemetry = &self.counters,
            .connection_id = 29,
            .protocol = .h2,
        };
    }

    pub fn snapshot(self: *const H2TestHarness) Snapshot {
        return self.counters.snapshot(.{
            .connections = .{ .active = 0, .limit_drops = 0 },
        });
    }
};
