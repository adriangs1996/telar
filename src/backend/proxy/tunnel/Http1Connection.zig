//! HTTP/1.1 for one intercepted CONNECT exchange: the generic relay drives
//! the connection and calls these methods for each step, which feed
//! exchange capture and finish each half with the outcome the step means.
const core = @import("telar-core");
const exchangecapture = @import("exchangecapture");
const owned = @import("../capture/owned.zig");
const httprelay = @import("httprelay");
const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const Exchange = @import("Exchange.zig");
const Producer = @import("../capture/Producer.zig");
const Half = owned.Half;
const StartOptions = @import("../capture/StartOptions.zig");
const RequestHead = httprelay.http1.RequestHead;
const http = httprelay.http1;
const connection_module = httprelay.http1;
const types = httprelay.http1;
const buffer_support = exchangecapture.buffer_support;
const ResponseHead = httprelay.http1.ResponseHead;
const Fragment = httprelay.http1.Fragment;
const Head = httprelay.http1.Head;
const Counters = @import("../Counters.zig");
const FakeSessionType = httprelay.http1.FakeSession;
const Config = exchangecapture.Config;
const GenericConnection = httprelay.http1.GenericConnection;
const GenericExchange = httprelay.http1.GenericExchange;
const Connection = @This();

pub const head_limit = core.Limit.declare("proxy.http1.max_head_bytes", "bytes", http.max_head_bytes);
pub const chunk_line_limit = core.Limit.declare("proxy.http1.max_chunk_line_bytes", "bytes", http.max_chunk_line_bytes);
pub const trailer_line_limit = core.Limit.declare("proxy.http1.max_trailer_line_bytes", "bytes", http.max_trailer_line_bytes);

const RelayConnection = GenericConnection(Connection);
const RelayExchange = GenericExchange(Connection);

io: std.Io,
session: *Session,
exchange: *Exchange,
captures: ?*Producer,
request_capture: ?*Half = null,
response_capture: ?*Half = null,

/// Binds an intercepted TLS session to its exchange.
///
/// ```zig
/// var connection = Connection.init(options);
/// ```
pub fn init(options: Http1Options) Connection {
    return .{
        .io = options.io,
        .session = options.session,
        .exchange = options.exchange,
        .captures = options.captures,
    };
}

/// Relays reusable HTTP/1.1 exchanges until close, failure, or upgrade.
/// Captures left open are discarded before returning.
///
/// ```zig
/// connection.run();
/// ```
pub fn run(self: *Connection) void {
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
    session: *Session,
    exchange: *Exchange,
    captures: ?*Producer = null,
};

/// Relays the next request head unchanged. While it waits for one, the
/// connection is idle and may be closed to make room; from the head's first
/// byte until its response ends, the exchange is in flight and it may not.
///
/// ```zig
/// const request = connection.readRequest() orelse return;
/// ```
pub fn readRequest(self: *Connection) ?RequestHead {
    self.beginCapture();
    self.exchange.enter(.idle);

    const parsed = http.relayHead(self.session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
    }, HeadCapture{
        .half = self.request_capture,
        .exchange = self.exchange,
        .side = .request,
        .session = self.session,
    }) orelse return null;

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

/// Relays the request body into the request capture.
///
/// ```zig
/// const forwarded = connection.relayRequestBody(request.body);
/// ```
pub fn relayRequestBody(self: *Connection, framing: types.BodyPlan) bool {
    const forwarded = http.relayBody(
        self.session,
        .{ .from = .child, .to = .origin, .framing = framing },
        BodyCapture{
            .part = .request_body,
            .half = self.request_capture,
            .exchange = self.exchange,
        },
    );

    if (forwarded) {
        self.finishCapture(.request, .finished);
    }

    return forwarded;
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
    producer.publish(self.io, half);
}

/// Relays informational responses, then the final one.
///
/// ```zig
/// const response = connection.relayResponse(request) orelse return null;
/// ```
pub fn relayResponse(self: *Connection, request: RequestHead) ?ResponseHead {
    while (true) {
        const head = http.relayHead(self.session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = request.response_context == .head_request,
        }, HeadCapture{
            .half = self.response_capture,
            .exchange = self.exchange,
            .side = .response,
            .session = self.session,
        }) orelse return null;

        if (head.message.informational) {
            if (self.response_capture) |half| {
                half.head.reset();
                half.captured_bytes = half.body.len;
            }
        }

        const forwarded = http.relayBody(
            self.session,
            .{ .from = .origin, .to = .child, .framing = head.framing },
            BodyCapture{
                .part = .response_body,
                .half = self.response_capture,
                .exchange = self.exchange,
            },
        );

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

/// Finishes the request capture of a request without a body.
///
/// ```zig
/// connection.publishRequest(request);
/// ```
pub fn publishRequest(self: *Connection, request: RequestHead) void {
    if (!request.body.hasBody()) {
        self.finishCapture(.request, .finished);
    }
}

/// Finishes the response capture with the outcome its status means.
///
/// ```zig
/// connection.publishResponse(response);
/// ```
pub fn publishResponse(self: *Connection, response: ResponseHead) void {
    self.finishCapture(.response, captureOutcome(response.status_code));
    self.exchange.endExchange();
}

fn captureOutcome(status_code: u16) buffer_support.Outcome {
    return if (status_code >= 400) .failed else .finished;
}

/// Fails both captures of an exchange the transport did not complete.
///
/// ```zig
/// connection.publishFailure();
/// ```
pub fn publishFailure(self: *Connection) void {
    self.finishCapture(.request, .failed);
    self.finishCapture(.response, .failed);
    self.exchange.endExchange();
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

fn relayUpgrade(self: *Connection) void {
    var outbound = self.io.concurrent(Connection.pumpUpgrade, .{
        self,
        UpgradeRoute{ .from = .child, .to = .origin },
    }) catch return;
    self.pumpUpgrade(.{ .from = .origin, .to = .child });
    outbound.await(self.io);
}

fn pumpUpgrade(self: *Connection, route: UpgradeRoute) void {
    var buffer: [16 * 1024]u8 = undefined;

    while (self.session.read(route.from, &buffer)) |len| {
        if (!self.session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        self.exchange.touch();
    }

    self.exchange.enter(.half_closed);
    self.session.halfClose(route.to);
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

test "final status maps to a finished or failed response capture" {
    inline for (.{ @as(u16, 200), 204, 399 }) |status_code| {
        try std.testing.expectEqual(buffer_support.Outcome.finished, captureOutcome(status_code));
    }

    inline for (.{ @as(u16, 400), 429, 599 }) |status_code| {
        try std.testing.expectEqual(buffer_support.Outcome.failed, captureOutcome(status_code));
    }
}

fn testExchange(counters: *Counters, host: []const u8) !Exchange {
    return .{
        .io = std.testing.io,
        .telemetry = counters,
        .connection_id = 19,
        .protocol = .http11,
        .host = try std.Io.net.HostName.init(host),
    };
}

test "HTTP1 capture de-frames split bodies without changing forwarded bytes" {
    const FakeSession = FakeSessionType;
    const request_head = "POST /upload?q=1 HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n";
    const request = request_head ++ "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    const response_head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    const response = response_head ++ "hello";

    for (1..request.len + 1) |split_size| {
        var producer: Producer = undefined;
        try producer.init(std.testing.allocator, .{
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
        var counters: Counters = .{};
        var exchange = try testExchange(&counters, "example.test");

        const request_half = producer.start(.{
            .protocol = .http11,
            .key = .{ .connection_id = exchange.connection_id, .stream_id = 0 },
            .side = .request,
            .host = exchange.host.bytes,
            .started_at_ms = 1,
        }).?;
        const parsed_request = http.relayHead(&session, .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
        }, HeadCapture{
            .half = request_half,
            .exchange = &exchange,
            .side = .request,
        }).?;
        try std.testing.expect(http.relayBody(&session, .{
            .from = .child,
            .to = .origin,
            .framing = parsed_request.framing,
        }, BodyCapture{
            .part = .request_body,
            .half = request_half,
            .exchange = &exchange,
        }));
        request_half.finish(.finished, 2);
        producer.publish(std.testing.io, request_half);

        const response_half = producer.start(.{
            .protocol = .http11,
            .key = .{ .connection_id = exchange.connection_id, .stream_id = 0 },
            .side = .response,
            .host = exchange.host.bytes,
            .started_at_ms = 1,
        }).?;
        const parsed_response = http.relayHead(&session, .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = false,
        }, HeadCapture{
            .half = response_half,
            .exchange = &exchange,
            .side = .response,
        }).?;
        try std.testing.expect(http.relayBody(&session, .{
            .from = .origin,
            .to = .child,
            .framing = parsed_response.framing,
        }, BodyCapture{
            .part = .response_body,
            .half = response_half,
            .exchange = &exchange,
        }));
        response_half.status_code = parsed_response.message.status_code;
        response_half.finish(.finished, 3);
        producer.publish(std.testing.io, response_half);
        exchange.record(.passthrough_connection);

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
    var producer: Producer = undefined;
    try producer.init(std.testing.allocator, .{
        .enabled = true,
        .max_part_bytes = 5,
        .max_exchange_bytes = 10,
        .max_total_bytes = 10,
    });
    defer producer.close(std.testing.io);
    var half = producer.start(.{
        .protocol = .http11,
        .key = .{ .connection_id = 1, .stream_id = 0 },
        .side = .request,
        .host = "example.test",
        .started_at_ms = 1,
    }).?;
    var session: FakeSession = .{ .child_input = wire, .max_read_bytes = 1 };
    var counters: Counters = .{};
    var exchange = try testExchange(&counters, "example.test");

    try std.testing.expect(http.relayBody(&session, .{
        .from = .child,
        .to = .origin,
        .framing = .chunked,
    }, BodyCapture{
        .part = .request_body,
        .half = half,
        .exchange = &exchange,
    }));
    try std.testing.expectEqualStrings(wire, session.originOutput());
    try std.testing.expectEqualStrings("Wikip", half.body.bytes());
    try std.testing.expect(half.body.truncated);
    half.deinit();
}

test "a head past its bound is counted and a line past its bound too" {
    const FakeSession = FakeSessionType;
    var counters: Counters = .{};
    var exchange = try testExchange(&counters, "example.test");
    const oversized: [http.max_head_bytes + 1]u8 = @splat('h');
    var head_session: FakeSession = .{
        .child_input = &oversized,
    };

    try std.testing.expect(http.relayHead(&head_session, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
    }, HeadCapture{
        .half = null,
        .exchange = &exchange,
        .side = .request,
    }) == null);
    try std.testing.expectEqualStrings("", head_session.originOutput());

    const long_line: [http.max_chunk_line_bytes + 1]u8 = @splat('f');
    var body_session: FakeSession = .{
        .child_input = &long_line,
    };
    try std.testing.expect(!http.relayBody(&body_session, .{
        .from = .child,
        .to = .origin,
        .framing = .chunked,
    }, BodyCapture{
        .part = .request_body,
        .exchange = &exchange,
    }));

    const snapshot = counters.snapshot(.{
        .connections = .{
            .active = 0,
            .limit_drops = 0,
        },
    });
    try std.testing.expectEqual(@as(u64, 1), snapshot.http1_heads_too_large);
    try std.testing.expectEqual(@as(u64, 1), snapshot.http1_chunk_lines_too_long);
}

/// Copies each forwarded head into the exchange half that captures it, and
/// answers a head past `http1.max_head_bytes` for the child: 431 for its
/// own request, 502 for the origin's response. Nothing of that head was
/// forwarded, and the connection ends.
const HeadCapture = struct {
    half: ?*Half,
    exchange: *Exchange,
    side: buffer_support.Side,
    /// Where the answer to a head past the bound goes; tests relay without one.
    session: ?*Session = null,

    pub fn head(self: HeadCapture, bytes: []const u8) void {
        self.exchange.touch();
        if (self.half) |half| {
            half.appendHead(bytes);
        }
    }

    /// A request's first byte starts its exchange: the connection is busy
    /// from here, even while the rest of the head arrives.
    pub fn headStarted(self: HeadCapture) void {
        if (self.side == .request) {
            self.exchange.enter(.open);
            self.exchange.beginExchange();
            return;
        }

        self.exchange.touch();
    }

    pub fn headTooLarge(self: HeadCapture) void {
        self.exchange.record(.http1_head_too_large);

        const session = self.session orelse return;
        const answer = switch (self.side) {
            .request => request_head_too_large,
            .response => response_head_too_large,
        };
        _ = session.writeAll(.child, answer);
    }
};

/// The answer to a request head past `http1.max_head_bytes`.
const request_head_too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
/// The answer to a response head past `http1.max_head_bytes`.
const response_head_too_large = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Copies each already-forwarded body fragment into the half that captures
/// it, and counts a chunk-size or trailer line past its bound.
const BodyCapture = struct {
    part: buffer_support.Part,
    half: ?*Half = null,
    exchange: *Exchange,

    /// Example: `observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });`
    pub fn observe(self: BodyCapture, fragment: Fragment) void {
        self.exchange.touch();
        if (self.half) |half| {
            _ = half.append(self.part, fragment.payload);
        }
    }

    pub fn lineTooLong(self: BodyCapture, line: http.FramingLine) void {
        self.exchange.record(switch (line) {
            .chunk_size => .http1_chunk_line_too_long,
            .trailer => .http1_trailer_line_too_long,
        });
    }
};

const UpgradeRoute = struct {
    from: Session.Side,
    to: Session.Side,
};
