//! HTTP/1.1 adapter for one intercepted CONNECT exchange.

const GenericExchangePort = @import("../http/GenericExchangePort.zig").Type;
const Http1Connection = @import("Http1Connection.zig");
const GenericExchange = @import("../http/GenericExchange.zig").Type;
const GenericPort = @import("../http/GenericPort.zig").Type;
const GenericConnection = @import("../http/GenericConnection.zig").Type;
const std = @import("std");
const RequestHeadType = @import("../http/RequestHead.zig");
const http = @import("../http/http.zig");
const connection_module = @import("../http/connection.zig");
const types = @import("../http/types.zig");
const RequestBodyObserver = @import("RequestBodyObserver.zig");
const exchange_mod = @import("exchange_support.zig");
const HalfType = @import("../capture/Half.zig");
const HeadSinkType = @import("../http/HeadSink.zig");
const buffer_support = @import("../capture/buffer_support.zig");
const ResponseHeadType = @import("../http/ResponseHead.zig");
const ResponseBodyObserver = @import("ResponseBodyObserver.zig");
const HeadType = @import("../http/Head.zig");
const request_support = @import("../provider/request_support.zig");
const middleware = @import("../middleware.zig");
const UpgradeRoute = @import("UpgradeRoute.zig");
const Http1TestHarness = @import("Http1TestHarness.zig");
const FakeSessionType = @import("../http/FakeSession.zig");
const ProducerType = @import("../capture/Producer.zig");
const ConfigType = @import("../capture/Config.zig");
const Http1CaptureGate = @import("Http1CaptureGate.zig");
const Observer = @import("../provider/Observer.zig");

const exchange_port: GenericExchangePort(Http1Connection) = .{
    .io = connectionIo,
    .relay_body = relayRequestBody,
    .relay_response = relayResponse,
};

const RelayExchange = GenericExchange(Http1Connection, exchange_port);

const connection_port: GenericPort(Http1Connection) = .{
    .read_request = relayRequestHead,
    .exchange = relayExchange,
    .publish_request = publishRequest,
    .publish_response = publishResponse,
    .publish_failure = publishFailure,
    .upgrade = upgrade,
};

pub const RelayConnection = GenericConnection(Http1Connection, connection_port);

fn connectionIo(connection: *Http1Connection) std.Io {
    return connection.io;
}

fn relayRequestHead(connection: *Http1Connection) ?RequestHeadType {
    connection.request.deinit();
    connection.beginCapture();

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
        .capture = headSink(connection.request_capture),
    }) orelse return null;

    return .{
        .classification = parsed.classification,
        .body = parsed.framing,
        .response_context = if (parsed.message.head_request) .head_request else .normal,
    };
}

fn relayExchange(connection: *Http1Connection, request: RequestHeadType) connection_module.ExchangeOutcome {
    return RelayExchange.execute(connection, request);
}

fn relayRequestBody(connection: *Http1Connection, framing: types.BodyPlan) bool {
    const inspect = connection.request.isActive();
    defer {
        if (inspect) {
            connection.request.deinit();
        }
    }

    const forwarded = http.relayBody(
        connection.session,
        .{ .from = .child, .to = .origin, .framing = framing },
        RequestBodyObserver{ .request = &connection.request, .capture_half = connection.request_capture },
    );

    if (forwarded and inspect) {
        finishRequest(connection);
    }

    if (forwarded) {
        finishCapture(connection, .request, .finished);
    }

    return forwarded;
}

fn finishRequest(connection: *Http1Connection) void {
    connection.exchange.publish(exchange_mod.requestPhase(connection.request.finish()), 0);
}

fn headSink(half: ?*HalfType) ?HeadSinkType {
    const owned = half orelse return null;

    return .{ .context = owned, .append_fn = captureHead };
}

fn captureHead(context: *anyopaque, bytes: []const u8) void {
    const half: *HalfType = @ptrCast(@alignCast(context));
    const part: buffer_support.Part = if (half.side == .request) .request_head else .response_head;
    _ = half.append(part, bytes);

    if (half.side == .request) {
        const line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return;
        var fields = std.mem.splitScalar(u8, bytes[0..line_end], ' ');
        const method = fields.next() orelse return;
        const target = fields.next() orelse return;
        half.setRoute(method, target);
    }

    if (headerValue(bytes, "content-encoding")) |encoding| {
        half.setEncoding(encoding);
    }
}

fn headerValue(bytes: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, wanted)) {
            continue;
        }

        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }

    return null;
}

fn finishCapture(connection: *Http1Connection, side: buffer_support.Side, outcome: buffer_support.Outcome) void {
    const producer = connection.captures orelse return;
    const slot = switch (side) {
        .request => &connection.request_capture,
        .response => &connection.response_capture,
    };
    const half = slot.* orelse return;
    slot.* = null;
    half.finish(outcome, std.Io.Timestamp.now(connection.io, .real).toMilliseconds());
    producer.publish(connection.io, .{
        .credential = connection.exchange.credential,
        .half = half,
    });
}

fn relayResponse(connection: *Http1Connection, request: RequestHeadType) ?ResponseHeadType {
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
            .capture = headSink(connection.response_capture),
        }) orelse return null;

        if (head.message.informational) {
            if (connection.response_capture) |half| {
                half.head.reset();
                half.captured_bytes = half.body.len;
            }
        }

        var observer: ResponseBodyObserver = .init(connection.exchange, .{
            .inspect_payload = shouldInspectResponse(request, head),
            .capture_half = connection.response_capture,
        });
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
            if (connection.response_capture) |half| {
                half.status_code = head.message.status_code;
            }

            return semanticResponse(head);
        }
    }
}

fn semanticResponse(head: HeadType) ResponseHeadType {
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

fn publishRequest(connection: *Http1Connection, request: RequestHeadType) void {
    if (shouldClassifyRequest(connection, request)) {
        connection.request.init(connection.exchange.dialect);
        return;
    }

    const classification: request_support.RequestClass = if (connection.exchange.dialect == .anthropic_messages and request.classification == .inference)
        .auxiliary
    else
        request.classification;
    connection.exchange.publish(exchange_mod.requestPhase(classification), 0);
    if (!request.body.hasBody()) {
        finishCapture(connection, .request, .finished);
    }
}

fn shouldClassifyRequest(connection: *const Http1Connection, request: RequestHeadType) bool {
    return connection.exchange.dialect == .anthropic_messages and request.classification == .inference and request.body.hasBody();
}

fn publishResponse(connection: *Http1Connection, response: ResponseHeadType) void {
    connection.exchange.status_code = response.status_code;
    connection.exchange.publish(responsePhase(response.status_code), 0);
    finishCapture(connection, .response, if (response.status_code >= 400) .failed else .finished);
}

fn responsePhase(status_code: u16) middleware.Phase {
    return if (status_code >= 400) .request_failed else .response_finished;
}

fn publishFailure(connection: *Http1Connection) void {
    connection.exchange.publish(.request_failed, 0);
    finishCapture(connection, .request, .failed);
    finishCapture(connection, .response, .failed);
}

fn upgrade(connection: *Http1Connection) void {
    connection.exchange.protocol = .upgraded;
    relayUpgrade(connection);
}

fn shouldInspectResponse(request: RequestHeadType, head: HeadType) bool {
    return request.classification == .inference and
        head.sse_body and
        head.message.status_code >= 200 and head.message.status_code < 300;
}

fn relayUpgrade(connection: *Http1Connection) void {
    var outbound = connection.io.concurrent(pumpUpgrade, .{
        connection,
        UpgradeRoute{ .from = .child, .to = .origin },
    }) catch return;
    pumpUpgrade(connection, .{ .from = .origin, .to = .child });
    outbound.await(connection.io);
    connection.exchange.publish(.response_finished, 0);
}

fn pumpUpgrade(connection: *Http1Connection, route: UpgradeRoute) void {
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
    var connection = Http1Connection.init(.{
        .io = std.testing.io,
        .transforms = undefined,
        .session = undefined,
        .exchange = &harness.exchange,
    });
    defer connection.request.deinit();
    const candidate: RequestHeadType = .{
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
    const request: RequestHeadType = .{
        .classification = .inference,
        .body = .none,
        .response_context = .normal,
    };
    const successful: HeadType = .{
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
        .dialect = harness.exchange.dialect,
    }).?;
    const request: RequestHeadType = .{
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
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(types.ResponseKind.informational, informational.kind);
    try std.testing.expectEqual(types.ConnectionPolicy.keep_alive, informational.connection);

    const upgraded = semanticResponse(.{
        .message = .{ .status_code = 101, .upgrade = true },
        .framing = .none,
        .classification = .auxiliary,
        .sse_body = false,
    });
    try std.testing.expectEqual(types.ResponseKind.upgrade, upgraded.kind);

    const closing = semanticResponse(.{
        .message = .{ .status_code = 200, .closes = true },
        .framing = .until_close,
        .classification = .auxiliary,
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

fn testCaptureProducer(producer: *ProducerType, context: *u8, config: ConfigType) !void {
    try producer.init(std.testing.allocator, .{
        .config = config,
        .gate = .{ .context = context, .is_live = Http1CaptureGate.accepts },
    });
}

test "HTTP1 capture de-frames split bodies without changing forwarded bytes" {
    const FakeSession = FakeSessionType;
    const request_head = "POST /upload?q=1 HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n";
    const request = request_head ++ "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    const response_head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    const response = response_head ++ "hello";

    for (1..request.len + 1) |split_size| {
        var gate_context: u8 = 0;
        var producer: ProducerType = undefined;
        try testCaptureProducer(&producer, &gate_context, .{
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
            .capture = headSink(request_half),
        }).?;
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
            .capture = headSink(response_half),
        }).?;
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
    var gate_context: u8 = 0;
    var producer: ProducerType = undefined;
    try testCaptureProducer(&producer, &gate_context, .{
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
