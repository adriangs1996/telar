//! HTTP/2 for one intercepted CONNECT exchange: the generic relay drives
//! both directions and calls these methods, which install provider
//! observers, capture streams and rewrites for the exchange's dialect.
const std = @import("std");
const Rewrite = @import("../Rewrite.zig");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const ResponseStreams = @import("../provider/ResponseStreams.zig");
const Streams = @import("../provider/Streams.zig");
const Producer = @import("../capture/Producer.zig");
const h2frames = @import("h2frames");
const Settings = h2frames.Settings;
const Stats = @import("../h2/Stats.zig");
const CaptureStreams = @import("CaptureStreams.zig");
const EventObserver = @import("EventObserver.zig");
const h2 = @import("../h2/h2.zig");
const relay_module = @import("../h2/relay.zig");
const RelayOptions = @import("../h2/RelayOptions.zig");
const middleware = @import("../middleware.zig");
const request_support = @import("../provider/request_support.zig");
const core = @import("telar-core");
const Channel = @import("../Channel.zig");
const Counters = @import("../Counters.zig");
const identity = @import("../identity.zig");
const Snapshot = @import("../Snapshot.zig");
const claude_transport = @import("../provider/claude_transport.zig");
const Registry = @import("../Registry.zig");
const Credential = @import("../Credential.zig");
const HeaderField = h2frames.HeaderField;
const Joiner = @import("../capture/Joiner.zig");
const GenericConnection = @import("../h2/GenericConnection.zig").Type;
const RelayContext = @This();

const RelayConnection = GenericConnection(RelayContext);

io: std.Io,
/// Rewrites applied to request heads; responses keep theirs.
request_rewrites: []const Rewrite,
session: *Session,
exchange: *Exchange,
responses: ?*ResponseStreams,
requests: ?*Streams,
captures: ?*Producer = null,

/// Relays both directions until the response side ends, then settles.
///
/// ```zig
/// relay_context.run();
/// ```
pub fn run(self: *RelayContext) void {
    RelayConnection.run(self.io, self);
}

/// Relays the request direction through the Claude request observers and
/// request capture.
///
/// ```zig
/// const stats = relay_context.relayRequest(&settings);
/// ```
pub fn relayRequest(self: *RelayContext, settings: *Settings) Stats {
    var captures = if (self.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = self.exchange,
        .side = .request,
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .exchange = self.exchange,
        .requests = self.requests,
        .captures = if (captures) |*streams| streams else null,
    };

    return h2.relay(self.session, self.relayOptions(settings, .request), &observer);
}
/// Relays the response direction through the Claude response observers and
/// response capture.
///
/// ```zig
/// const stats = relay_context.relayResponse(&settings);
/// ```
pub fn relayResponse(self: *RelayContext, settings: *Settings) Stats {
    var captures = if (self.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = self.exchange,
        .side = .response,
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .exchange = self.exchange,
        .responses = self.responses,
        .captures = if (captures) |*streams| streams else null,
    };

    return h2.relay(self.session, self.relayOptions(settings, .response), &observer);
}
fn relayOptions(self: *RelayContext, settings: *Settings, direction: relay_module.Direction) RelayOptions {
    const rewrites = switch (direction) {
        .request => self.request_rewrites,
        .response => &.{},
    };

    return h2.relayOptions(direction, settings, .{
        .watched_routes = request_support.inferenceRoutes(self.exchange.dialect),
        .transformation = if (rewrites.len == 0) null else .{ .rewrites = rewrites },
    });
}
/// Counts a direction whose header decoding failed.
///
/// ```zig
/// relay_context.recordDecodeFailure(.request);
/// ```
pub fn recordDecodeFailure(self: *RelayContext, _: relay_module.Direction) void {
    self.exchange.record(.h2_decode_failure);
}
/// Publishes the stream-zero failure that settles any exchange still open.
///
/// ```zig
/// relay_context.settle();
/// ```
pub fn settle(self: *RelayContext) void {
    // A stream-zero failure settles any exchange left open when the transport
    // disappeared. The agent model ignores it after every stream settled.
    self.exchange.publish(.request_failed, 0);
}
const claude_end_turn_event =
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n" ++
    "\n";
const claude_primary_request =
    "{\"messages\":[{\"role\":\"user\",\"content\":\"private\"}]," ++
    "\"tools\":[{\"name\":\"Read\"}],\"stream\":true}";
const claude_startup_request =
    "{\"model\":\"claude-haiku\",\"max_tokens\":1," ++
    "\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
test "Claude request bodies refine interleaved route candidates per stream" {
    var harness: H2TestHarness = .{};
    try harness.init();
    var requests = Streams.init(.anthropic_messages);
    defer requests.deinit();
    var observer: EventObserver = .{
        .exchange = &harness.exchange,
        .requests = &requests,
    };

    observer.emit(.{ .lifecycle = .{ .stage = .request_started, .stream_id = 63, .status_code = 0, .watched = true } });
    observer.emit(.{ .lifecycle = .{ .stage = .request_started, .stream_id = 65, .status_code = 0, .watched = true } });
    try std.testing.expectEqual(@as(u64, 0), harness.observations.metrics().queued);

    const primary_split = claude_primary_request.len / 2;
    const startup_split = claude_startup_request.len / 2;
    observer.emit(.{ .request_body = .{ .stream_id = 63, .bytes = claude_primary_request[0..primary_split] } });
    observer.emit(.{ .request_body = .{ .stream_id = 65, .bytes = claude_startup_request[0..startup_split] } });
    observer.emit(.{ .request_body = .{ .stream_id = 63, .bytes = claude_primary_request[primary_split..] } });
    observer.emit(.{ .request_body = .{ .stream_id = 65, .bytes = claude_startup_request[startup_split..] } });
    observer.emit(.{ .request_finished = .{ .stream_id = 65 } });
    observer.emit(.{ .request_finished = .{ .stream_id = 63 } });

    try harness.expectObservations(&.{
        .{ .phase = .auxiliary_request_started, .stream_id = 65 },
        .{ .phase = .request_started, .stream_id = 63 },
    });
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_inference_requests);
}
test "only request heads with rewrites are transcoded" {
    var harness: H2TestHarness = .{};
    try harness.init();
    var settings: Settings = .{};
    var context: RelayContext = .{
        .io = std.testing.io,
        .request_rewrites = claude_transport.requestRewrites(.anthropic_messages),
        .session = undefined,
        .exchange = &harness.exchange,
        .responses = null,
        .requests = null,
    };

    try std.testing.expect(context.relayOptions(&settings, .request).transformation != null);
    try std.testing.expect(context.relayOptions(&settings, .response).transformation == null);

    context.request_rewrites = claude_transport.requestRewrites(.openai_responses);
    try std.testing.expect(context.relayOptions(&settings, .request).transformation == null);
    try std.testing.expect(context.relayOptions(&settings, .response).transformation == null);
}
test "final DATA publishes Claude completion before transport completion" {
    var harness: H2TestHarness = .{};
    try harness.init();
    var responses = ResponseStreams.init(std.testing.allocator, .anthropic_messages);
    defer responses.deinit();
    var observer: EventObserver = .{
        .exchange = &harness.exchange,
        .responses = &responses,
    };

    observer.emit(.{ .lifecycle = .{
        .stage = .request_started,
        .watched = true,
        .stream_id = 31,
        .status_code = 0,
    } });
    observer.emit(.{ .lifecycle = .{
        .stage = .response_activity,
        .stream_id = 31,
        .status_code = 200,
    } });
    observer.emit(.{ .response_body = .{
        .stream_id = 31,
        .status_code = 200,
        .sse_body = true,
        .bytes = claude_end_turn_event,
    } });
    observer.emit(.{ .lifecycle = .{
        .stage = .response_ended,
        .stream_id = 31,
        .status_code = 200,
    } });

    try harness.expectObservations(&.{
        .{ .phase = .request_started, .stream_id = 31 },
        .{ .phase = .response_activity, .stream_id = 31 },
        .{ .phase = .provider_turn_completed, .stream_id = 31 },
        .{ .phase = .response_finished, .stream_id = 31 },
    });
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 0), harness.snapshot().claude_failure_observations);
}
test "decode failure increments only the HTTP2 counter" {
    var harness: H2TestHarness = .{};
    try harness.init();
    var context: RelayContext = .{
        .io = std.testing.io,
        .request_rewrites = &.{},
        .session = undefined,
        .exchange = &harness.exchange,
        .responses = null,
        .requests = null,
    };

    context.recordDecodeFailure(.request);

    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().h2_decode_failures);
}
test "HTTP2 capture keeps interleaved streams independent for unknown dialects" {
    var registry: Registry = .{};
    try registry.register(std.testing.io, &.{
        .pane_id = try core.pane(13),
        .pane_generation = 17,
        .token = .{0x24} ** identity.token_bytes,
    });
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .config = .{
            .enabled = true,
            .max_part_bytes = 512,
            .max_exchange_bytes = 1024,
            .max_total_bytes = 4096,
        },
        .credentials = &registry,
    });
    defer producer.close(std.testing.io);
    var harness: H2TestHarness = .{};
    try harness.init();
    harness.exchange.dialect = .unknown;
    harness.exchange.host = try std.Io.net.HostName.init("example.test");
    var requests: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .request };
    defer requests.deinit();
    var responses: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .response };
    defer responses.deinit();
    var request_observer: EventObserver = .{ .exchange = &harness.exchange, .captures = &requests };
    var response_observer: EventObserver = .{ .exchange = &harness.exchange, .captures = &responses };
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
            .partial => |value| {
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
    registry: Registry = .{},
    observations: Channel = undefined,
    counters: Counters = .{},
    exchange: Exchange = undefined,

    /// Builds the harness at its final address: the channel borrows the
    /// registry and the exchange borrows the channel.
    pub fn init(self: *H2TestHarness) !void {
        const credential: Credential = .{
            .pane_id = try core.pane(13),
            .pane_generation = 17,
            .token = .{0x24} ** identity.token_bytes,
        };
        try self.registry.register(std.testing.io, &credential);
        self.observations.init(&self.registry);
        self.exchange = .{
            .io = std.testing.io,
            .observations = &self.observations,
            .telemetry = &self.counters,
            .credential = credential,
            .dialect = .anthropic_messages,
            .connection_id = 29,
            .protocol = .h2,
        };
    }

    /// Drains every queued observation and compares it in order.
    pub fn expectObservations(self: *H2TestHarness, expected: []const ExpectedObservation) !void {
        for (expected) |wanted| {
            const event = self.observations.tryReceive(std.testing.io) orelse return error.MissingObservation;
            try std.testing.expectEqual(wanted.phase, event.phase);
            try std.testing.expectEqual(wanted.stream_id, event.stream_id);
        }

        try std.testing.expect(self.observations.tryReceive(std.testing.io) == null);
    }

    pub fn snapshot(self: *const H2TestHarness) Snapshot {
        return self.counters.snapshot(.{
            .connections = .{ .active = 0, .limit_drops = 0 },
            .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
        });
    }
};
const ExpectedObservation = struct {
    phase: middleware.Phase,
    stream_id: u32,
};
