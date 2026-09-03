//! HTTP/1.1 adapter for one intercepted CONNECT exchange.

const std = @import("std");
const core = @import("telar-core");
const http = @import("../http/root.zig");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange.zig");

const Io = std.Io;
const schema = core.schema;

pub const Options = struct {
    io: Io,
    transforms: *const middleware.TransformPipeline,
    session: *tls.Session,
    exchange: *exchange_mod.Exchange,
};

pub const Connection = struct {
    io: Io,
    transforms: *const middleware.TransformPipeline,
    session: *tls.Session,
    exchange: *exchange_mod.Exchange,
    request: provider.RequestObserver = .{},

    /// Binds an intercepted TLS session to its exchange and immutable header
    /// transformation pipeline.
    ///
    /// ```zig
    /// var connection = Connection.init(options);
    /// ```
    pub fn init(options: Options) Connection {
        return .{
            .io = options.io,
            .transforms = options.transforms,
            .session = options.session,
            .exchange = options.exchange,
        };
    }

    /// Relays reusable HTTP/1.1 exchanges until close, failure, or upgrade.
    /// Provider request and response observers are scrubbed before returning.
    ///
    /// ```zig
    /// connection.run();
    /// ```
    pub fn run(connection: *Connection) void {
        defer connection.request.deinit();
        RelayConnection.run(connection);
    }
};

const exchange_port: http.ExchangePort(Connection) = .{
    .io = connectionIo,
    .relay_body = relayRequestBody,
    .relay_response = relayResponse,
};

const RelayExchange = http.Exchange(Connection, exchange_port);

const connection_port: http.ConnectionPort(Connection) = .{
    .read_request = relayRequestHead,
    .exchange = relayExchange,
    .publish_request = publishRequest,
    .publish_response = publishResponse,
    .publish_failure = publishFailure,
    .upgrade = upgrade,
};

const RelayConnection = http.Connection(Connection, connection_port);

const RequestBodyObserver = struct {
    request: *provider.RequestObserver,

    /// Feeds one already-forwarded payload fragment to request classification.
    ///
    /// ```zig
    /// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
    /// ```
    pub fn observe(observer: RequestBodyObserver, fragment: http.BodyFragment) void {
        observer.request.feed(fragment.payload);
    }
};

const ResponseBodyObserver = struct {
    exchange: *exchange_mod.Exchange,
    response: provider.ResponseObserver,
    inspect_payload: bool,

    fn init(exchange: *exchange_mod.Exchange, inspect_payload: bool) ResponseBodyObserver {
        return .{
            .exchange = exchange,
            .response = .init(exchange.dialect),
            .inspect_payload = inspect_payload,
        };
    }

    /// Publishes forwarding activity and inspects eligible SSE payload bytes
    /// for provider turn completion.
    ///
    /// ```zig
    /// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
    /// ```
    pub fn observe(observer: *ResponseBodyObserver, fragment: http.BodyFragment) void {
        if (fragment.forwarded_bytes != 0) {
            observer.exchange.publish(.response_activity, 0);
        }

        if (observer.inspect_payload and fragment.payload.len != 0) {
            if (observer.response.dialect == .anthropic_messages) {
                observer.exchange.record(.claude_sse_payload_fragment);
            }

            if (observer.response.feed(fragment.payload)) {
                observer.exchange.publish(.provider_turn_completed, 0);
            }
        }
    }

    fn deinit(observer: *ResponseBodyObserver) void {
        observer.response.deinit();
        observer.inspect_payload = false;
    }
};

const UpgradeRoute = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
};

fn connectionIo(connection: *Connection) Io {
    return connection.io;
}

fn relayRequestHead(connection: *Connection) ?http.RequestHead {
    connection.request.deinit();

    const parsed = http.relayHeadTransformed(connection.session, .{
        .route = .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
            .dialect = connection.exchange.dialect,
        },
        .pipeline = connection.transforms,
        .io = connection.io,
        .context = connection.exchange.transformContext(.{
            .direction = .request,
            .kind = .request,
            .stream_id = 0,
        }),
    }) orelse return null;

    return .{
        .classification = parsed.classification,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}

fn relayExchange(connection: *Connection, request: http.RequestHead) http.ExchangeOutcome {
    return RelayExchange.execute(connection, request);
}

fn relayRequestBody(connection: *Connection, framing: http.BodyPlan) bool {
    const inspect = connection.request.isActive();
    defer {
        if (inspect) {
            connection.request.deinit();
        }
    }

    const forwarded = http.relayBody(
        connection.session,
        .{ .from = .child, .to = .origin, .framing = framing },
        RequestBodyObserver{ .request = &connection.request },
    );

    if (forwarded and inspect) {
        finishRequest(connection);
    }

    return forwarded;
}

fn finishRequest(connection: *Connection) void {
    connection.exchange.publish(exchange_mod.requestPhase(connection.request.finish()), 0);
}

fn relayResponse(connection: *Connection, request: http.RequestHead) ?http.ResponseHead {
    while (true) {
        const head = http.relayHeadTransformed(connection.session, .{
            .route = .{
                .from = .origin,
                .to = .child,
                .is_response = true,
                .response_to_head = request.response_context == .head_request,
            },
            .pipeline = connection.transforms,
            .io = connection.io,
            .context = connection.exchange.transformContext(.{
                .direction = .response,
                .kind = .response,
                .stream_id = 0,
            }),
        }) orelse return null;

        var observer: ResponseBodyObserver = .init(connection.exchange, shouldInspectResponse(request, head));
        const forwarded = http.relayBody(
            connection.session,
            .{ .from = .origin, .to = .child, .framing = head.framing },
            &observer,
        );
        observer.deinit();

        if (!forwarded) {
            return null;
        }

        if (!head.message.informational) {
            return semanticResponse(head);
        }
    }
}

fn semanticResponse(head: http.Head) http.ResponseHead {
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

fn publishRequest(connection: *Connection, request: http.RequestHead) void {
    if (shouldClassifyRequest(connection, request)) {
        connection.request.init(connection.exchange.dialect);
        return;
    }

    const classification: http.RequestClass = if (connection.exchange.dialect == .anthropic_messages and request.classification == .inference)
        .auxiliary
    else
        request.classification;
    connection.exchange.publish(exchange_mod.requestPhase(classification), 0);
}

fn shouldClassifyRequest(connection: *const Connection, request: http.RequestHead) bool {
    return connection.exchange.dialect == .anthropic_messages and request.classification == .inference and request.body.hasBody();
}

fn publishResponse(connection: *Connection, response: http.ResponseHead) void {
    connection.exchange.status_code = response.status_code;
    connection.exchange.publish(responsePhase(response.status_code), 0);
}

fn responsePhase(status_code: u16) middleware.Phase {
    return if (status_code >= 400) .request_failed else .response_finished;
}

fn publishFailure(connection: *Connection) void {
    connection.exchange.publish(.request_failed, 0);
}

fn upgrade(connection: *Connection) void {
    connection.exchange.protocol = .upgraded;
    relayUpgrade(connection);
}

fn shouldInspectResponse(request: http.RequestHead, head: http.Head) bool {
    return request.classification == .inference and
        head.sse_body and
        head.message.status_code >= 200 and head.message.status_code < 300;
}

fn relayUpgrade(connection: *Connection) void {
    var outbound = connection.io.concurrent(pumpUpgrade, .{
        connection,
        UpgradeRoute{ .from = .child, .to = .origin },
    }) catch return;
    pumpUpgrade(connection, .{ .from = .origin, .to = .child });
    outbound.await(connection.io);
    connection.exchange.publish(.response_finished, 0);
}

fn pumpUpgrade(connection: *Connection, route: UpgradeRoute) void {
    var buffer: [16 * 1024]u8 = undefined;

    while (connection.session.read(route.from, &buffer)) |len| {
        if (!connection.session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        if (route.from == .origin) {
            connection.exchange.publish(.response_activity, 0);
        }
    }

    connection.session.halfClose(route.to);
}

const Capture = struct {
    events: [16]middleware.Event = undefined,
    len: usize = 0,

    fn observe(context: *anyopaque, _: Io, event: middleware.Event) void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.events[capture.len] = event;
        capture.len += 1;
    }
};

const TestHarness = struct {
    capture: Capture = .{},
    pipeline: middleware.Pipeline = .{},
    counters: metrics.Counters = .{},
    exchange: exchange_mod.Exchange = undefined,

    fn init(harness: *TestHarness) !void {
        try harness.pipeline.add(.{ .context = &harness.capture, .observe = Capture.observe });
        harness.exchange = .{
            .io = std.testing.io,
            .pipeline = &harness.pipeline,
            .telemetry = &harness.counters,
            .credential = .{
                .pane_id = try schema.id.pane(7),
                .pane_generation = 11,
                .token = .{0x42} ** identity.token_bytes,
            },
            .dialect = .anthropic_messages,
            .connection_id = 19,
            .protocol = .http11,
        };
    }

    fn expectPhases(harness: *const TestHarness, expected: []const middleware.Phase) !void {
        try std.testing.expectEqual(expected.len, harness.capture.len);

        for (expected, harness.capture.events[0..harness.capture.len]) |phase, event| {
            try std.testing.expectEqual(phase, event.phase);
        }
    }

    fn snapshot(harness: *const TestHarness) metrics.Snapshot {
        return harness.counters.snapshot(.{
            .connections = .{ .active = 0, .limit_drops = 0 },
            .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
        });
    }
};

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
    var harness: TestHarness = .{};
    try harness.init();
    var connection = Connection.init(.{
        .io = std.testing.io,
        .transforms = undefined,
        .session = undefined,
        .exchange = &harness.exchange,
    });
    defer connection.request.deinit();
    const candidate: http.RequestHead = .{
        .classification = .inference,
        .body = .{ .content_length = claude_startup_request.len },
        .response_context = .normal,
    };
    const observer: RequestBodyObserver = .{ .request = &connection.request };

    publishRequest(&connection, candidate);
    try std.testing.expectEqual(@as(usize, 0), harness.capture.len);
    observer.observe(.{ .payload = claude_startup_request, .forwarded_bytes = claude_startup_request.len });
    finishRequest(&connection);
    connection.request.deinit();

    publishRequest(&connection, .{
        .classification = .inference,
        .body = .none,
        .response_context = .normal,
    });

    var primary = candidate;
    primary.body = .{ .content_length = claude_primary_request.len };
    publishRequest(&connection, primary);
    const split = claude_primary_request.len / 2;
    observer.observe(.{ .payload = claude_primary_request[0..split], .forwarded_bytes = split });
    observer.observe(.{
        .payload = claude_primary_request[split..],
        .forwarded_bytes = claude_primary_request.len - split,
    });
    finishRequest(&connection);

    try harness.expectPhases(&.{
        .auxiliary_request_started,
        .auxiliary_request_started,
        .request_started,
    });
    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().claude_inference_requests);
}

test "only successful inference SSE responses are inspected" {
    const request: http.RequestHead = .{
        .classification = .inference,
        .body = .none,
        .response_context = .normal,
    };
    const successful: http.Head = .{
        .message = .{ .status_code = 200 },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = true,
    };

    try std.testing.expect(shouldInspectResponse(request, successful));
    try std.testing.expect(!shouldInspectResponse(.{
        .classification = .auxiliary,
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
    const FakeSession = @import("../http/test_support.zig").FakeSession;
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
    var harness: TestHarness = .{};
    try harness.init();

    const parsed_request = http.relayHead(&session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
        .dialect = harness.exchange.dialect,
    }).?;
    const request: http.RequestHead = .{
        .classification = parsed_request.classification,
        .body = parsed_request.framing,
        .response_context = .normal,
    };
    harness.exchange.publish(exchange_mod.requestPhase(request.classification), 0);

    const parsed_response = http.relayHead(&session, .{
        .from = .origin,
        .to = .child,
        .is_response = true,
        .response_to_head = false,
    }).?;
    var observer: ResponseBodyObserver = .init(&harness.exchange, shouldInspectResponse(request, parsed_response));
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
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.informational, informational.kind);
    try std.testing.expectEqual(http.ConnectionPolicy.keep_alive, informational.connection);

    const upgraded = semanticResponse(.{
        .message = .{ .status_code = 101, .upgrade = true },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.upgrade, upgraded.kind);

    const closing = semanticResponse(.{
        .message = .{ .status_code = 200, .closes = true },
        .framing = .until_close,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(http.ResponseKind.final, closing.kind);
    try std.testing.expectEqual(http.ConnectionPolicy.close, closing.connection);
    try std.testing.expectEqual(http.BodyPlan.until_close, closing.body);
}

test "final status maps to response completion or failure" {
    inline for (.{ @as(u16, 200), 204, 399 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.response_finished, responsePhase(status_code));
    }

    inline for (.{ @as(u16, 400), 429, 599 }) |status_code| {
        try std.testing.expectEqual(middleware.Phase.request_failed, responsePhase(status_code));
    }
}
