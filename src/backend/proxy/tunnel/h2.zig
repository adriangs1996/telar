//! HTTP/2 adapter for one intercepted CONNECT exchange.

const std = @import("std");
const core = @import("telar-core");
const h2 = @import("../h2/root.zig");
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
    gpa: std.mem.Allocator,
    transforms: *const middleware.TransformPipeline,
    has_custom_transformers: bool,
    session: *tls.Session,
    exchange: *exchange_mod.Exchange,
};

pub const Connection = struct {
    options: Options,

    /// Binds an HTTP/2 TLS session to its exchange and immutable transform
    /// configuration.
    ///
    /// ```zig
    /// var connection = Connection.init(options);
    /// ```
    pub fn init(options: Options) Connection {
        return .{ .options = options };
    }

    /// Relays both HTTP/2 directions and owns provider stream observers for
    /// the duration of the connection.
    ///
    /// ```zig
    /// connection.run();
    /// ```
    pub fn run(connection: *Connection) void {
        const options = connection.options;
        var responses = provider.ResponseStreams.init(options.gpa, options.exchange.dialect);
        defer responses.deinit();
        var requests = provider.RequestStreams.init(options.exchange.dialect);
        defer requests.deinit();
        var relay: RelayContext = .{
            .io = options.io,
            .transforms = options.transforms,
            .has_custom_transformers = options.has_custom_transformers,
            .session = options.session,
            .exchange = options.exchange,
            .responses = if (options.exchange.dialect == .anthropic_messages) &responses else null,
            .requests = if (options.exchange.dialect == .anthropic_messages) &requests else null,
        };

        RelayConnection.run(&relay);
    }
};

const RelayContext = struct {
    io: Io,
    transforms: *const middleware.TransformPipeline,
    has_custom_transformers: bool,
    session: *tls.Session,
    exchange: *exchange_mod.Exchange,
    responses: ?*provider.ResponseStreams,
    requests: ?*provider.RequestStreams,
};

const connection_port: h2.ConnectionPort(RelayContext) = .{
    .io = connectionIo,
    .relay_request = relayRequest,
    .relay_response = relayResponse,
    .record_decode_failure = recordDecodeFailure,
    .settle = settle,
};

const RelayConnection = h2.Connection(RelayContext, connection_port);

const EventObserver = struct {
    exchange: *exchange_mod.Exchange,
    responses: ?*provider.ResponseStreams = null,
    requests: ?*provider.RequestStreams = null,

    /// Routes borrowed HTTP/2 observations through provider request and
    /// response semantics before publishing lifecycle evidence.
    ///
    /// ```zig
    /// observer.emit(.{ .request_body = .{ .stream_id = 3, .bytes = fragment } });
    /// ```
    pub fn emit(observer: *EventObserver, event: h2.Event) void {
        switch (event) {
            .lifecycle => |lifecycle| observer.observeLifecycle(lifecycle),
            .request_body => |body| {
                const requests = observer.requests orelse return;

                requests.feed(.{
                    .stream_id = body.stream_id,
                    .bytes = body.bytes,
                });
            },
            .request_finished => |finished| observer.finishRequest(finished.stream_id),
            .response_body => |body| {
                const responses = observer.responses orelse return;

                if (shouldInspectBody(body)) {
                    observer.exchange.record(.claude_sse_payload_fragment);

                    if (responses.feed(body.stream_id, body.bytes)) {
                        observer.exchange.publishStatus(.{
                            .phase = .provider_turn_completed,
                            .stream_id = body.stream_id,
                            .status_code = 0,
                        });
                    }
                }
            },
        }
    }

    fn observeLifecycle(observer: *EventObserver, lifecycle: h2.Lifecycle) void {
        if (observer.shouldClassifyRequest(lifecycle)) {
            const requests = observer.requests.?;
            if (!requests.start(lifecycle.stream_id)) {
                publishRequestClass(observer.exchange, lifecycle.stream_id, .auxiliary);
            }

            return;
        }

        if (lifecycle.phase == .request_failed) {
            if (observer.requests) |requests| {
                requests.discard(lifecycle.stream_id);
            }
        }

        observer.exchange.publishStatus(.{
            .phase = lifecycle.phase,
            .stream_id = lifecycle.stream_id,
            .status_code = lifecycle.status_code,
        });

        if (observer.responses) |responses| {
            if (lifecycle.stream_id != 0 and
                (lifecycle.phase == .response_finished or lifecycle.phase == .request_failed))
            {
                responses.finish(lifecycle.stream_id);
            }
        }
    }

    fn shouldClassifyRequest(observer: *const EventObserver, lifecycle: h2.Lifecycle) bool {
        return observer.exchange.dialect == .anthropic_messages and observer.requests != null and lifecycle.phase == .request_started;
    }

    fn finishRequest(observer: *EventObserver, stream_id: u32) void {
        const requests = observer.requests orelse return;
        const classification = requests.finish(stream_id) orelse return;
        publishRequestClass(observer.exchange, stream_id, classification);
    }
};

fn connectionIo(context: *RelayContext) Io {
    return context.io;
}

fn relayRequest(context: *RelayContext, settings: *h2.Settings) h2.Stats {
    var observer: EventObserver = .{
        .exchange = context.exchange,
        .requests = context.requests,
    };

    return h2.relay(context.session, relayOptions(context, settings, .request), &observer);
}

fn relayResponse(context: *RelayContext, settings: *h2.Settings) h2.Stats {
    var observer: EventObserver = .{
        .exchange = context.exchange,
        .responses = context.responses,
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

fn publishRequestClass(exchange: *exchange_mod.Exchange, stream_id: u32, classification: provider.RequestClass) void {
    exchange.publishStatus(.{
        .phase = exchange_mod.requestPhase(classification),
        .stream_id = stream_id,
        .status_code = 0,
    });
}

fn shouldInspectBody(body: h2.ResponseBody) bool {
    return body.sse_body and body.status_code >= 200 and body.status_code < 300;
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
                .pane_id = try schema.id.pane(13),
                .pane_generation = 17,
                .token = .{0x24} ** identity.token_bytes,
            },
            .dialect = .anthropic_messages,
            .connection_id = 29,
            .protocol = .h2,
        };
    }

    fn expectObservations(harness: *const TestHarness, expected: []const ExpectedObservation) !void {
        try std.testing.expectEqual(expected.len, harness.capture.len);

        for (expected, harness.capture.events[0..harness.capture.len]) |wanted, event| {
            try std.testing.expectEqual(wanted.phase, event.phase);
            try std.testing.expectEqual(wanted.stream_id, event.stream_id);
        }
    }

    fn snapshot(harness: *const TestHarness) metrics.Snapshot {
        return harness.counters.snapshot(.{
            .connections = .{ .active = 0, .limit_drops = 0 },
            .observations = .{ .queued = 0, .high_water = 0, .dropped = 0 },
        });
    }
};

const ExpectedObservation = struct {
    phase: middleware.Phase,
    stream_id: u32,
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
