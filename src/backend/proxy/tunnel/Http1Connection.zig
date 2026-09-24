//! HTTP/1.1 for one intercepted CONNECT exchange: the generic relay drives
//! the connection and calls these methods for each step, which classify
//! requests by the exchange's dialect, publish lifecycle phases and feed
//! capture.
const exchangecapture = @import("exchangecapture");
const owned = @import("../capture/owned.zig");
const httprelay = @import("httprelay");
const std = @import("std");
const Rewrite = httprelay.Rewrite;
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const Observer = @import("../provider/Observer.zig");
const Half = owned.Half;
const StartOptions = @import("../capture/StartOptions.zig");
const RequestHead = httprelay.http1.RequestHead;
const http = httprelay.http1;
const connection_module = httprelay.http1;
const types = httprelay.http1;
const exchange_mod = @import("exchange_support.zig");
const buffer_support = exchangecapture.buffer_support;
const ResponseHead = httprelay.http1.ResponseHead;
const ResponseObserver = @import("../provider/ResponseObserver.zig");
const Fragment = httprelay.http1.Fragment;
const Head = httprelay.http1.Head;
const request_support = @import("../provider/request_support.zig");
const middleware = @import("../middleware.zig");
const core = @import("telar-core");
const Channel = @import("../Channel.zig");
const Counters = @import("../Counters.zig");
const identity = @import("../identity.zig");
const Snapshot = @import("../Snapshot.zig");
const FakeSessionType = httprelay.http1.FakeSession;
const Config = exchangecapture.Config;
const Registry = @import("../Registry.zig");
const Credential = @import("../Credential.zig");
const GenericConnection = httprelay.http1.GenericConnection;
const GenericExchange = httprelay.http1.GenericExchange;
const Connection = @This();

const RelayConnection = GenericConnection(Connection);
const RelayExchange = GenericExchange(Connection);

io: std.Io,
/// Rewrites applied to request heads; responses keep theirs.
request_rewrites: []const Rewrite,
session: *Session,
exchange: *Exchange,
captures: ?*Producer,
request: Observer = .{},
request_capture: ?*Half = null,
response_capture: ?*Half = null,

/// Binds an intercepted TLS session to its exchange and the rewrites its
/// request heads receive.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: Http1Options) Connection {
    return .{
        .io = options.io,
        .request_rewrites = options.request_rewrites,
        .session = options.session,
        .exchange = options.exchange,
        .captures = options.captures,
    };
}

/// Relays reusable HTTP/1.1 exchanges until close, failure, or upgrade.
/// Provider request and response observers are scrubbed before returning.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(self: *Connection) void {
    defer self.request.deinit();
    defer self.discardCaptures();
    RelayConnection.run(self);
}

fn discardCaptures(self: *Connection) void {
    if (self.request_capture) |half| {
        half.deinit();
        self.request_capture = null;
    }

    if (self.response_capture) |half| {
        half.deinit();
        self.response_capture = null;
    }
}

pub fn beginCapture(self: *Connection) void {
    self.discardCaptures();
    const producer = self.captures orelse return;
    const started_at_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    const base: StartOptions = .{
        .credential = self.exchange.credential,
        .dialect = self.exchange.dialect,
        .protocol = self.exchange.protocol,
        .key = .{ .connection_id = self.exchange.connection_id, .stream_id = 0 },
        .side = .request,
        .host = self.exchange.host.bytes,
        .started_at_ms = started_at_ms,
    };
    self.request_capture = producer.start(base);
    var response = base;
    response.side = .response;
    self.response_capture = producer.start(response);
}

const Http1Options = struct {
    io: std.Io,
    request_rewrites: []const Rewrite,
    session: *Session,
    exchange: *Exchange,
    captures: ?*Producer = null,
};

/// Relays the next request head, rewritten when a rewrite matches.
///
/// ```zig
/// const request = connection.readRequest() orelse return;
/// ```
pub fn readRequest(self: *Connection) ?RequestHead {
    self.request.deinit();
    self.beginCapture();

    const parsed = http.relayHeadTransformed(self.session, .{
        .route = .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
            .watched_routes = request_support.inferenceRoutes(self.exchange.dialect),
        },
        .rewrites = self.request_rewrites,
    }, HeadCapture{ .half = self.request_capture }) orelse return null;

    return .{
        .watched = parsed.watched,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}
/// Runs one request/response exchange.
///
/// ```zig
/// const outcome = connection.relayExchange(request);
/// ```
pub fn relayExchange(self: *Connection, request: RequestHead) connection_module.ExchangeOutcome {
    return RelayExchange.execute(self.io, self, request);
}
/// Relays the request body and finishes request classification.
///
/// ```zig
/// const forwarded = connection.relayRequestBody(request.body);
/// ```
pub fn relayRequestBody(self: *Connection, framing: types.BodyPlan) bool {
    const inspect = self.request.isActive();
    defer {
        if (inspect) {
            self.request.deinit();
        }
    }

    const forwarded = http.relayBody(
        self.session,
        .{ .from = .child, .to = .origin, .framing = framing },
        RequestBodyObserver{ .request = &self.request, .capture_half = self.request_capture },
    );

    if (forwarded and inspect) {
        self.finishRequest();
    }

    if (forwarded) {
        self.finishCapture(.request, .finished);
    }

    return forwarded;
}
fn finishRequest(self: *Connection) void {
    self.exchange.publish(exchange_mod.requestPhase(self.request.finish()), 0);
}
fn finishCapture(self: *Connection, side: buffer_support.Side, outcome: buffer_support.Outcome) void {
    const producer = self.captures orelse return;
    const slot = switch (side) {
        .request => &self.request_capture,
        .response => &self.response_capture,
    };
    const half = slot.* orelse return;
    slot.* = null;
    half.finish(outcome, std.Io.Timestamp.now(self.io, .real).toMilliseconds());
    producer.publish(self.io, .{
        .credential = self.exchange.credential,
        .half = half,
    });
}
/// Relays informational responses, then the final one.
///
/// ```zig
/// const response = connection.relayResponse(request) orelse return null;
/// ```
pub fn relayResponse(self: *Connection, request: RequestHead) ?ResponseHead {
    while (true) {
        const head = http.relayHeadTransformed(self.session, .{
            .route = .{
                .from = .origin,
                .to = .child,
                .is_response = true,
                .response_to_head = request.response_context == .head_request,
            },
            .rewrites = &.{},
        }, HeadCapture{ .half = self.response_capture }) orelse return null;

        if (head.message.informational) {
            if (self.response_capture) |half| {
                half.head.reset();
                half.captured_bytes = half.body.len;
            }
        }

        var observer: ResponseBodyObserver = .init(self.exchange, .{
            .inspect_payload = shouldInspectResponse(request, head),
            .capture_half = self.response_capture,
        });
        const forwarded = http.relayBody(
            self.session,
            .{ .from = .origin, .to = .child, .framing = head.framing },
            &observer,
        );
        observer.deinit();

        if (!forwarded) {
            return null;
        }

        if (!head.message.informational) {
            if (self.response_capture) |half| {
                half.status_code = head.message.status_code;
            }

            return semanticResponse(head);
        }
    }
}
fn semanticResponse(head: Head) ResponseHead {
    return .{
        .status_code = head.message.status_code,
        .body = head.framing,
        .kind = if (head.message.informational)
            .informational
        else if (head.message.upgrade)
            .upgrade
        else
            .final,
        .connection = if (head.message.closes) .close else .keep_alive,
    };
}
/// Publishes the request phase, or defers it until the body classifies it.
///
/// ```zig
/// connection.publishRequest(request);
/// ```
pub fn publishRequest(self: *Connection, request: RequestHead) void {
    if (self.shouldClassifyRequest(request)) {
        self.request.init(self.exchange.dialect);
        return;
    }

    const classification: request_support.RequestClass = if (self.exchange.dialect == .anthropic_messages and request.watched)
        .auxiliary
    else
        requestClass(request);
    self.exchange.publish(exchange_mod.requestPhase(classification), 0);
    if (!request.body.hasBody()) {
        self.finishCapture(.request, .finished);
    }
}
fn shouldClassifyRequest(self: *const Connection, request: RequestHead) bool {
    return self.exchange.dialect == .anthropic_messages and request.watched and request.body.hasBody();
}
/// A watched route is an inference route of the tunnel's dialect.
fn requestClass(request: RequestHead) request_support.RequestClass {
    return if (request.watched) .inference else .auxiliary;
}
/// Publishes the final status and finishes the response capture.
///
/// ```zig
/// connection.publishResponse(response);
/// ```
pub fn publishResponse(self: *Connection, response: ResponseHead) void {
    self.exchange.status_code = response.status_code;
    self.exchange.publish(responsePhase(response.status_code), 0);
    self.finishCapture(.response, if (response.status_code >= 400) .failed else .finished);
}
fn responsePhase(status_code: u16) middleware.Phase {
    return if (status_code >= 400) .request_failed else .response_finished;
}
/// Publishes a failed exchange and fails both captures.
///
/// ```zig
/// connection.publishFailure();
/// ```
pub fn publishFailure(self: *Connection) void {
    self.exchange.publish(.request_failed, 0);
    self.finishCapture(.request, .failed);
    self.finishCapture(.response, .failed);
}
/// Relays an upgraded connection until either side closes.
///
/// ```zig
/// connection.upgrade();
/// ```
pub fn upgrade(self: *Connection) void {
    self.exchange.protocol = .upgraded;
    self.relayUpgrade();
}
fn shouldInspectResponse(request: RequestHead, head: Head) bool {
    return request.watched and
        head.sse_body and
        head.message.status_code >= 200 and head.message.status_code < 300;
}
fn relayUpgrade(self: *Connection) void {
    var outbound = self.io.concurrent(Connection.pumpUpgrade, .{
        self,
        UpgradeRoute{ .from = .child, .to = .origin },
    }) catch return;
    self.pumpUpgrade(.{ .from = .origin, .to = .child });
    outbound.await(self.io);
    self.exchange.publish(.response_finished, 0);
}
fn pumpUpgrade(self: *Connection, route: UpgradeRoute) void {
    var buffer: [16 * 1024]u8 = undefined;

    while (self.session.read(route.from, &buffer)) |len| {
        if (!self.session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        if (route.from == .origin) {
            self.exchange.publish(.response_activity, 0);
        }
    }

    self.session.halfClose(route.to);
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
test "Claude request bodies refine route candidates before publication" {
    var harness: Http1TestHarness = .{};
    try harness.init();
    var connection = Connection.init(.{
        .io = std.testing.io,
        .request_rewrites = &.{},
        .session = undefined,
        .exchange = &harness.exchange,
    });
    defer connection.request.deinit();
    const candidate: RequestHead = .{
        .watched = true,
        .body = .{ .content_length = claude_startup_request.len },
        .response_context = .normal,
    };
    const observer: RequestBodyObserver = .{ .request = &connection.request };

    connection.publishRequest(candidate);
    try std.testing.expectEqual(@as(u64, 0), harness.observations.metrics().queued);
    observer.observe(.{ .payload = claude_startup_request, .forwarded_bytes = claude_startup_request.len });
    connection.finishRequest();
    connection.request.deinit();

    connection.publishRequest(.{
        .watched = true,
        .body = .none,
        .response_context = .normal,
    });

    var primary = candidate;
    primary.body = .{ .content_length = claude_primary_request.len };
    connection.publishRequest(primary);
    const split = claude_primary_request.len / 2;
    observer.observe(.{ .payload = claude_primary_request[0..split], .forwarded_bytes = split });
    observer.observe(.{
        .payload = claude_primary_request[split..],
        .forwarded_bytes = claude_primary_request.len - split,
    });
    connection.finishRequest();

    try harness.expectPhases(&.{
        .auxiliary_request_started,
        .auxiliary_request_started,
        .request_started,
    });
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_inference_requests);
}
test "only successful inference SSE responses are inspected" {
    const request: RequestHead = .{
        .watched = true,
        .body = .none,
        .response_context = .normal,
    };
    const successful: Head = .{
        .message = .{ .status_code = 200 },
        .framing = .none,
        .watched = false,
        .sse_body = true,
    };

    try std.testing.expect(shouldInspectResponse(request, successful));
    try std.testing.expect(!shouldInspectResponse(.{
        .watched = false,
        .body = .none,
        .response_context = .normal,
    }, successful));

    var non_sse = successful;
    non_sse.sse_body = false;
    try std.testing.expect(!shouldInspectResponse(request, non_sse));

    inline for (.{ @as(u16, 199), 300, 429, 500 }) |status_code| {
        var failed = successful;
        failed.message.status_code = status_code;
        try std.testing.expect(!shouldInspectResponse(request, failed));
    }
}
test "Claude SSE completion is published after forwarded response activity" {
    const FakeSession = FakeSessionType;
    const response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{claude_end_turn_event.len}) ++ "\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        claude_end_turn_event;
    var session: FakeSession = .{
        .child_input = "POST /v1/messages HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        .origin_input = response,
    };
    var harness: Http1TestHarness = .{};
    try harness.init();

    const parsed_request = http.relayHead(&session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
        .watched_routes = request_support.inferenceRoutes(harness.exchange.dialect),
    }, HeadCapture{ .half = null }).?;
    const request: RequestHead = .{
        .watched = parsed_request.watched,
        .body = parsed_request.framing,
        .response_context = .normal,
    };
    harness.exchange.publish(exchange_mod.requestPhase(requestClass(request)), 0);

    const parsed_response = http.relayHead(&session, .{
        .from = .origin,
        .to = .child,
        .is_response = true,
        .response_to_head = false,
    }, HeadCapture{ .half = null }).?;
    var observer: ResponseBodyObserver = .init(&harness.exchange, .{
        .inspect_payload = shouldInspectResponse(request, parsed_response),
        .capture_half = null,
    });
    defer observer.deinit();

    try std.testing.expect(http.relayBody(
        &session,
        .{ .from = .origin, .to = .child, .framing = parsed_response.framing },
        &observer,
    ));
    harness.exchange.status_code = parsed_response.message.status_code;
    harness.exchange.publish(responsePhase(harness.exchange.status_code), 0);

    try harness.expectPhases(&.{
        .request_started,
        .response_activity,
        .provider_turn_completed,
        .response_finished,
    });
    try std.testing.expectEqualStrings(session.child_input, session.originOutput());
    try std.testing.expectEqualStrings(response, session.childOutput());
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_inference_requests);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_sse_payload_fragments);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_turn_completions);
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_successful_responses);
    try std.testing.expectEqual(@as(u64, 0), harness.snapshot().claude_failure_observations);
}
test "response metadata preserves final routing semantics" {
    const informational = semanticResponse(.{
        .message = .{ .status_code = 100, .informational = true },
        .framing = .none,
        .watched = false,
        .sse_body = false,
    });
    try std.testing.expectEqual(types.ResponseKind.informational, informational.kind);
    try std.testing.expectEqual(types.ConnectionPolicy.keep_alive, informational.connection);

    const upgraded = semanticResponse(.{
        .message = .{ .status_code = 101, .upgrade = true },
        .framing = .none,
        .watched = false,
        .sse_body = false,
    });
    try std.testing.expectEqual(types.ResponseKind.upgrade, upgraded.kind);

    const closing = semanticResponse(.{
        .message = .{ .status_code = 200, .closes = true },
        .framing = .until_close,
        .watched = false,
        .sse_body = false,
    });
    try std.testing.expectEqual(types.ResponseKind.final, closing.kind);
    try std.testing.expectEqual(types.ConnectionPolicy.close, closing.connection);
    try std.testing.expectEqual(types.BodyPlan.until_close, closing.body);
}
test "final status maps to response completion or failure" {
    inline for (.{ @as(u16, 200), 204, 399 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.response_finished, responsePhase(status_code));
    }

    inline for (.{ @as(u16, 400), 429, 599 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.request_failed, responsePhase(status_code));
    }
}
fn testCaptureProducer(producer: *Producer, registry: *Registry, config: Config) !void {
    try producer.init(std.testing.allocator, .{
        .config = config,
        .credentials = registry,
    });
}
/// The credential `Http1TestHarness` authenticates with.
fn harnessCredential() !Credential {
    return .{
        .pane_id = try core.pane(7),
        .pane_generation = 11,
        .token = .{0x42} ** identity.token_bytes,
    };
}
/// A registry holding the harness credential.
fn harnessRegistry() !Registry {
    var registry: Registry = .{};
    try registry.register(std.testing.io, &try harnessCredential());
    return registry;
}
test "HTTP1 capture de-frames split bodies without changing forwarded bytes" {
    const FakeSession = FakeSessionType;
    const request_head = "POST /upload?q=1 HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n";
    const request = request_head ++ "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    const response_head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    const response = response_head ++ "hello";

    for (1..request.len + 1) |split_size| {
        var registry = try harnessRegistry();
        var producer: Producer = undefined;
        try testCaptureProducer(&producer, &registry, .{
            .enabled = true,
            .max_part_bytes = 512,
            .max_exchange_bytes = 1024,
            .max_total_bytes = 1024,
        });
        defer producer.close(std.testing.io);
        var session: FakeSession = .{
            .child_input = request,
            .origin_input = response,
            .max_read_bytes = split_size,
        };
        var harness: Http1TestHarness = .{};
        try harness.init();
        harness.exchange.dialect = .unknown;
        harness.exchange.host = try std.Io.net.HostName.init("example.test");

        const request_half = producer.start(.{
            .credential = harness.exchange.credential,
            .dialect = harness.exchange.dialect,
            .protocol = .http11,
            .key = .{ .connection_id = harness.exchange.connection_id, .stream_id = 0 },
            .side = .request,
            .host = harness.exchange.host.bytes,
            .started_at_ms = 1,
        }).?;
        const parsed_request = http.relayHead(&session, .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
        }, HeadCapture{ .half = request_half }).?;
        var request_observer: Observer = .{};
        try std.testing.expect(http.relayBody(&session, .{
            .from = .child,
            .to = .origin,
            .framing = parsed_request.framing,
        }, RequestBodyObserver{ .request = &request_observer, .capture_half = request_half }));
        request_half.finish(.finished, 2);
        producer.publish(std.testing.io, .{ .credential = harness.exchange.credential, .half = request_half });

        const response_half = producer.start(.{
            .credential = harness.exchange.credential,
            .dialect = harness.exchange.dialect,
            .protocol = .http11,
            .key = .{ .connection_id = harness.exchange.connection_id, .stream_id = 0 },
            .side = .response,
            .host = harness.exchange.host.bytes,
            .started_at_ms = 1,
        }).?;
        const parsed_response = http.relayHead(&session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = false,
        }, HeadCapture{ .half = response_half }).?;
        var response_observer = ResponseBodyObserver.init(&harness.exchange, .{
            .inspect_payload = false,
            .capture_half = response_half,
        });
        try std.testing.expect(http.relayBody(&session, .{
            .from = .origin,
            .to = .child,
            .framing = parsed_response.framing,
        }, &response_observer));
        response_observer.deinit();
        response_half.status_code = parsed_response.message.status_code;
        response_half.finish(.finished, 3);
        producer.publish(std.testing.io, .{ .credential = harness.exchange.credential, .half = response_half });

        const captured_request = try producer.receive(std.testing.io);
        defer captured_request.deinit();
        const captured_response = try producer.receive(std.testing.io);
        defer captured_response.deinit();
        try std.testing.expectEqualStrings(request_head, captured_request.head.bytes());
        try std.testing.expectEqualStrings("Wikipedia", captured_request.body.bytes());
        try std.testing.expectEqualStrings("POST", captured_request.method());
        try std.testing.expectEqualStrings("/upload?q=1", captured_request.target());
        try std.testing.expectEqualStrings(response_head, captured_response.head.bytes());
        try std.testing.expectEqualStrings("hello", captured_response.body.bytes());
        try std.testing.expectEqual(@as(u16, 200), captured_response.status_code);
        try std.testing.expectEqualStrings(request, session.originOutput());
        try std.testing.expectEqualStrings(response, session.childOutput());
    }
}
test "capture truncation never truncates HTTP1 forwarding" {
    const FakeSession = FakeSessionType;
    const wire = "9\r\nWikipedia\r\n0\r\n\r\n";
    var registry = try harnessRegistry();
    var producer: Producer = undefined;
    try testCaptureProducer(&producer, &registry, .{
        .enabled = true,
        .max_part_bytes = 5,
        .max_exchange_bytes = 10,
        .max_total_bytes = 10,
    });
    defer producer.close(std.testing.io);
    var harness: Http1TestHarness = .{};
    try harness.init();
    var half = producer.start(.{
        .credential = harness.exchange.credential,
        .dialect = .unknown,
        .protocol = .http11,
        .key = .{ .connection_id = 1, .stream_id = 0 },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
    var request_observer: Observer = .{};
    var session: FakeSession = .{ .child_input = wire, .max_read_bytes = 1 };

    try std.testing.expect(http.relayBody(&session, .{
        .from = .child,
        .to = .origin,
        .framing = .chunked,
    }, RequestBodyObserver{ .request = &request_observer, .capture_half = half }));
    try std.testing.expectEqualStrings(wire, session.originOutput());
    try std.testing.expectEqualStrings("Wikip", half.body.bytes());
    try std.testing.expect(half.body.truncated);
    half.deinit();
}
const ResponseBodyObserver = struct {
    exchange: *Exchange,
    response: ResponseObserver,
    inspect_payload: bool,
    capture_half: ?*Half,

    pub fn init(exchange: *Exchange, options: ResponseObserverOptions) ResponseBodyObserver {
        return .{
            .exchange = exchange,
            .response = .init(exchange.dialect),
            .inspect_payload = options.inspect_payload,
            .capture_half = options.capture_half,
        };
    }

    /// Publishes forwarding activity and inspects eligible SSE payload bytes
    /// for provider turn completion.
    ///
    /// ```zig
    /// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
    /// ```
    pub fn observe(self: *ResponseBodyObserver, fragment: Fragment) void {
        if (self.capture_half) |half| {
            _ = half.append(.response_body, fragment.payload);
        }

        if (fragment.forwarded_bytes != 0) {
            self.exchange.publish(.response_activity, 0);
        }

        if (self.inspect_payload and fragment.payload.len != 0) {
            if (self.response.dialect == .anthropic_messages) {
                self.exchange.record(.claude_sse_payload_fragment);
            }

            if (self.response.feed(fragment.payload)) {
                self.exchange.publish(.provider_turn_completed, 0);
            }
        }
    }

    pub fn deinit(self: *ResponseBodyObserver) void {
        self.response.deinit();
        self.inspect_payload = false;
        self.capture_half = null;
    }
};
/// Copies each forwarded head into the exchange half that captures it.
const HeadCapture = struct {
    half: ?*Half,

    pub fn head(self: HeadCapture, bytes: []const u8) void {
        if (self.half) |half| {
            half.appendHead(bytes);
        }
    }
};
const Http1TestHarness = struct {
    registry: Registry = .{},
    observations: Channel = undefined,
    counters: Counters = .{},
    exchange: Exchange = undefined,

    /// Builds the harness at its final address: the channel borrows the
    /// registry and the exchange borrows the channel.
    pub fn init(self: *Http1TestHarness) !void {
        const credential = try harnessCredential();
        try self.registry.register(std.testing.io, &credential);
        self.observations.init(&self.registry);
        self.exchange = .{
            .io = std.testing.io,
            .observations = &self.observations,
            .telemetry = &self.counters,
            .credential = credential,
            .dialect = .anthropic_messages,
            .connection_id = 19,
            .protocol = .http11,
        };
    }

    /// Drains every queued observation and compares its phase in order.
    pub fn expectPhases(self: *Http1TestHarness, expected: []const middleware.Phase) !void {
        for (expected) |phase| {
            const event = self.observations.tryReceive(std.testing.io) orelse return error.MissingObservation;
            try std.testing.expectEqual(phase, event.phase);
        }

        try std.testing.expect(self.observations.tryReceive(std.testing.io) == null);
    }

    pub fn snapshot(self: *const Http1TestHarness) Snapshot {
        return self.counters.snapshot(.{
            .connections = .{ .active = 0, .limit_drops = 0 },
            .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
        });
    }
};
const RequestBodyObserver = struct {
    request: *Observer,
    capture_half: ?*Half = null,

    /// Feeds one already-forwarded payload fragment to request classification.
    ///
    /// ```zig
    /// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
    /// ```
    pub fn observe(self: RequestBodyObserver, fragment: Fragment) void {
        self.request.feed(fragment.payload);
        if (self.capture_half) |half| {
            _ = half.append(.request_body, fragment.payload);
        }
    }
};
const ResponseObserverOptions = struct {
    inspect_payload: bool,
    capture_half: ?*Half,
};
const UpgradeRoute = struct {
    from: Session.Side,
    to: Session.Side,
};
