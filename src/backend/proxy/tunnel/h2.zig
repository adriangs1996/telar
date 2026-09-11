//! HTTP/2 adapter for one intercepted CONNECT exchange.

const std = @import("std");
const core = @import("telar-core");
const capture = @import("../capture/root.zig");
const h2 = @import("../h2/root.zig");
const identity = @import("../identity.zig");
const metrics = @import("../metrics.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");
const tls = @import("../tls.zig");
const exchange_mod = @import("exchange_support.zig");

pub const Io = std.Io;
pub const schema = core.schema;

pub const Options = @import("H2Options.zig");

pub const Connection = @import("H2Connection.zig");

const RelayContext = @import("RelayContext.zig");

const connection_port: h2.ConnectionPort(RelayContext) = .{
    .io = connectionIo,
    .relay_request = relayRequest,
    .relay_response = relayResponse,
    .record_decode_failure = recordDecodeFailure,
    .settle = settle,
};

pub const RelayConnection = h2.Connection(RelayContext, connection_port);

const EventObserver = @import("EventObserver.zig");

const CaptureSlot = @import("CaptureSlot.zig");

const CaptureStreams = @import("CaptureStreams.zig");

fn connectionIo(context: *RelayContext) Io {
    return context.io;
}

fn relayRequest(context: *RelayContext, settings: *h2.Settings) h2.Stats {
    var captures = if (context.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = context.exchange,
        .side = .request,
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .exchange = context.exchange,
        .requests = context.requests,
        .captures = if (captures) |*streams| streams else null,
    };

    return h2.relay(context.session, relayOptions(context, settings, .request), &observer);
}

fn relayResponse(context: *RelayContext, settings: *h2.Settings) h2.Stats {
    var captures = if (context.captures) |producer| CaptureStreams{
        .producer = producer,
        .exchange = context.exchange,
        .side = .response,
    } else null;
    defer if (captures) |*streams| streams.deinit();
    var observer: EventObserver = .{
        .exchange = context.exchange,
        .responses = context.responses,
        .captures = if (captures) |*streams| streams else null,
    };

    return h2.relay(context.session, relayOptions(context, settings, .response), &observer);
}

fn relayOptions(context: *RelayContext, settings: *h2.Settings, direction: h2.Direction) h2.RelayOptions {
    const kind: middleware.HeaderKind = switch (direction) {
        .request => .request,
        .response => .response,
    };
    const transform_direction: middleware.Direction = switch (direction) {
        .request => .request,
        .response => .response,
    };

    return h2.relayOptions(direction, settings, .{
        .dialect = context.exchange.dialect,
        .transformation = if (!shouldTransform(context, direction)) null else .{
            .pipeline = context.transforms,
            .io = context.io,
            .context = context.exchange.transformContext(.{
                .direction = transform_direction,
                .kind = kind,
                .stream_id = 0,
            }),
        },
    });
}

fn shouldTransform(context: *const RelayContext, direction: h2.Direction) bool {
    if (context.has_custom_transformers) {
        return true;
    }

    return context.exchange.dialect == .anthropic_messages and direction == .request;
}

fn recordDecodeFailure(context: *RelayContext, _: h2.Direction) void {
    context.exchange.record(.h2_decode_failure);
}

fn settle(context: *RelayContext) void {
    // A stream-zero failure settles any exchange left open when the transport
    // disappeared. The agent model ignores it after every stream settled.
    context.exchange.publish(.request_failed, 0);
}

pub fn publishRequestClass(exchange: *exchange_mod.Exchange, stream_id: u32, classification: provider.RequestClass) void {
    exchange.publishStatus(.{
        .phase = exchange_mod.requestPhase(classification),
        .stream_id = stream_id,
        .status_code = 0,
    });
}

pub fn shouldInspectBody(body: h2.ResponseBody) bool {
    return body.sse_body and body.status_code >= 200 and body.status_code < 300;
}

const Capture = @import("H2Capture.zig");

const TestHarness = @import("H2TestHarness.zig");

const ExpectedObservation = @import("ExpectedObservation.zig");

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
    var harness: TestHarness = .{};
    try harness.init();
    var requests = provider.RequestStreams.init(.anthropic_messages);
    defer requests.deinit();
    var observer: EventObserver = .{
        .exchange = &harness.exchange,
        .requests = &requests,
    };

    observer.emit(.{ .lifecycle = .{ .phase = .request_started, .stream_id = 63, .status_code = 0 } });
    observer.emit(.{ .lifecycle = .{ .phase = .request_started, .stream_id = 65, .status_code = 0 } });
    try std.testing.expectEqual(@as(usize, 0), harness.capture.len);

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

test "payload inspection requires a successful SSE response body" {
    inline for (.{ @as(u16, 199), 300, 429, 500 }) |status_code| {
        try std.testing.expect(!shouldInspectBody(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    inline for (.{ @as(u16, 200), 204, 299 }) |status_code| {
        try std.testing.expect(shouldInspectBody(.{
            .stream_id = 1,
            .status_code = status_code,
            .sse_body = true,
            .bytes = "",
        }));
    }

    try std.testing.expect(!shouldInspectBody(.{
        .stream_id = 1,
        .status_code = 200,
        .sse_body = false,
        .bytes = "",
    }));
}

test "built-in Claude negotiation transforms only request heads" {
    var harness: TestHarness = .{};
    try harness.init();
    var transforms: middleware.TransformPipeline = .{};
    var context: RelayContext = .{
        .io = std.testing.io,
        .transforms = &transforms,
        .has_custom_transformers = false,
        .session = undefined,
        .exchange = &harness.exchange,
        .responses = null,
        .requests = null,
    };

    try std.testing.expect(shouldTransform(&context, .request));
    try std.testing.expect(!shouldTransform(&context, .response));

    harness.exchange.dialect = .openai_responses;
    try std.testing.expect(!shouldTransform(&context, .request));
    try std.testing.expect(!shouldTransform(&context, .response));

    context.has_custom_transformers = true;
    try std.testing.expect(shouldTransform(&context, .request));
    try std.testing.expect(shouldTransform(&context, .response));
}

test "final DATA publishes Claude completion before transport completion" {
    var harness: TestHarness = .{};
    try harness.init();
    var responses = provider.ResponseStreams.init(std.testing.allocator, .anthropic_messages);
    defer responses.deinit();
    var observer: EventObserver = .{
        .exchange = &harness.exchange,
        .responses = &responses,
    };

    observer.emit(.{ .lifecycle = .{
        .phase = .request_started,
        .stream_id = 31,
        .status_code = 0,
    } });
    observer.emit(.{ .lifecycle = .{
        .phase = .response_activity,
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
        .phase = .response_finished,
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
    var harness: TestHarness = .{};
    try harness.init();
    var transforms: middleware.TransformPipeline = .{};
    var context: RelayContext = .{
        .io = std.testing.io,
        .transforms = &transforms,
        .has_custom_transformers = false,
        .session = undefined,
        .exchange = &harness.exchange,
        .responses = null,
        .requests = null,
    };

    recordDecodeFailure(&context, .request);

    try std.testing.expectEqual(@as(u64, 1), harness.snapshot().h2_decode_failures);
}

const CaptureGate = @import("H2CaptureGate.zig");

test "HTTP2 capture keeps interleaved streams independent for unknown dialects" {
    var gate_context: u8 = 0;
    var producer: capture.Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .config = .{
            .enabled = true,
            .max_part_bytes = 512,
            .max_exchange_bytes = 1024,
            .max_total_bytes = 4096,
        },
        .gate = .{ .context = &gate_context, .is_live = CaptureGate.accepts },
    });
    defer producer.close(std.testing.io);
    var harness: TestHarness = .{};
    try harness.init();
    harness.exchange.dialect = .unknown;
    harness.exchange.host = try Io.net.HostName.init("example.test");
    var requests: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .request };
    defer requests.deinit();
    var responses: CaptureStreams = .{ .producer = &producer, .exchange = &harness.exchange, .side = .response };
    defer responses.deinit();
    var request_observer: EventObserver = .{ .exchange = &harness.exchange, .captures = &requests };
    var response_observer: EventObserver = .{ .exchange = &harness.exchange, .captures = &responses };
    const first_request_headers = [_]h2.HeaderField{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/first" },
    };
    const second_request_headers = [_]h2.HeaderField{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/second" },
    };
    const response_headers = [_]h2.HeaderField{.{ .name = ":status", .value = "200" }};

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
    response_observer.emit(.{ .lifecycle = .{ .phase = .response_finished, .stream_id = 1, .status_code = 200 } });
    response_observer.emit(.{ .lifecycle = .{ .phase = .response_finished, .stream_id = 3, .status_code = 200 } });

    var joiner = capture.Joiner.init(30_000);
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
