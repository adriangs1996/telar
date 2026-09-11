//! Public HTTP/1.1 relay for intercepted TLS streams.
//!
//! `connection.zig` owns exchange ordering and connection policy. `head.zig`
//! reads and analyzes heads, `transform.zig` chooses whether to rewrite them,
//! and `body.zig` relays bodies without changing their wire representation.

const head = @import("head_support.zig");
const body = @import("body.zig");
const MessageType = @import("Message.zig");
const types = @import("types.zig");
const HeadType = @import("Head.zig");
const RouteType = @import("Route.zig");
const provider = @import("../provider/request_support.zig");
const connection = @import("connection.zig");
const GenericExchangePort = @import("GenericExchangePort.zig").Type;
const GenericExchange = @import("GenericExchange.zig").Type;
const GenericPort = @import("GenericPort.zig").Type;
const GenericConnection = @import("GenericConnection.zig").Type;
const MessageRouteType = @import("MessageRoute.zig");
const HeadTransformType = @import("HeadTransform.zig");
const transform = @import("transform.zig");
const std = @import("std");
const FakeSession = @import("FakeSession.zig");
const IgnoreTestObserver = @import("IgnoreTestObserver.zig");
const TransformationType = @import("../Transformation.zig");
const middleware = @import("../middleware.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const ConnectionIntegration = @import("ConnectionIntegration.zig");

pub const max_head_bytes = head.max_bytes;
pub const max_chunk_line_bytes = body.max_chunk_line_bytes;
pub const Message = @import("Message.zig");
pub const Framing = types.BodyPlan;
pub const Head = @import("Head.zig");
pub const BodyFragment = @import("Fragment.zig");
pub const BodyRoute = @import("Route.zig");
pub const BodyPlan = types.BodyPlan;
pub const RequestClass = provider.RequestClass;
pub const ResponseContext = types.ResponseContext;
pub const ResponseKind = types.ResponseKind;
pub const ConnectionPolicy = types.ConnectionPolicy;
pub const RequestHead = @import("RequestHead.zig");
pub const ResponseHead = @import("ResponseHead.zig");
pub const ExchangeOutcome = connection.ExchangeOutcome;

pub const MessageRoute = @import("MessageRoute.zig");

pub const HeadSink = @import("HeadSink.zig");

pub const HeadTransform = @import("HeadTransform.zig");

/// Relays one complete HTTP/1.1 message and returns its metadata.
///
/// ```zig
/// const message = relay(session, route, &observer);
/// ```
pub fn relay(session: anytype, route: MessageRouteType, observer: anytype) ?MessageType {
    const parsed = relayHead(session, route) orelse return null;

    if (!relayBody(session, .{
        .from = route.from,
        .to = route.to,
        .framing = parsed.framing,
    }, observer)) {
        return null;
    }

    return parsed.message;
}

/// Relays exactly one HTTP head without consuming body bytes.
///
/// The connection owner can therefore run the request body and response
/// concurrently for `Expect: 100-continue` and early final responses.
///
/// ```zig
/// const head = relayHead(session, route);
/// ```
pub fn relayHead(session: anytype, route: MessageRouteType) ?HeadType {
    var buffer: [head.max_bytes]u8 = undefined;
    const len = head.read(session, route.from, &buffer) orelse return null;
    if (route.capture) |capture| {
        capture.append(buffer[0..len]);
    }

    if (!session.writeAll(route.to, buffer[0..len])) {
        return null;
    }

    return head.analyze(buffer[0..len], .{
        .is_response = route.is_response,
        .response_to_head = route.response_to_head,
        .dialect = route.dialect,
    });
}

/// Relays one HTTP head after applying the configured transformation pipeline.
///
/// Invalid, oversized, or framing-changing results preserve the original head.
/// The pipeline never receives the session, and this function performs the one
/// network write selected by its decision.
///
/// ```zig
/// const head = relayHeadTransformed(session, transformation);
/// ```
pub fn relayHeadTransformed(session: anytype, transformation: HeadTransformType) ?HeadType {
    if (transformation.pipeline.len == 0) {
        var route = transformation.route;
        route.capture = transformation.capture;
        return relayHead(session, route);
    }

    var original: [head.max_bytes]u8 = undefined;
    const original_len = head.read(session, transformation.route.from, &original) orelse return null;
    if (transformation.capture) |capture| {
        capture.append(original[0..original_len]);
    }
    const original_head = head.analyze(original[0..original_len], .{
        .is_response = transformation.route.is_response,
        .response_to_head = transformation.route.response_to_head,
        .dialect = transformation.route.dialect,
    }) orelse return null;

    var encoded: [head.max_bytes]u8 = undefined;
    var selected_head = original_head;
    const selected_bytes = switch (transform.decide(.{
        .original = original[0..original_len],
        .original_head = original_head,
        .is_response = transformation.route.is_response,
        .response_to_head = transformation.route.response_to_head,
        .pipeline = transformation.pipeline,
        .io = transformation.io,
        .context = transformation.context,
        .output = &encoded,
    })) {
        .preserve => original[0..original_len],
        .replace => |replacement| select: {
            selected_head = replacement.head;
            break :select encoded[0..replacement.len];
        },
    };

    if (!session.writeAll(transformation.route.to, selected_bytes)) {
        return null;
    }

    return selected_head;
}

/// Relays one HTTP body and exposes only successfully forwarded fragments.
///
/// ```zig
/// const forwarded = relayBody(session, .{
///     .from = .origin,
///     .to = .child,
///     .framing = response.framing,
/// }, &observer);
/// ```
pub fn relayBody(session: anytype, route: RouteType, observer: anytype) bool {
    return body.relay(session, route, observer);
}

test "request head is forwarded before its body is consumed" {
    const request = "POST /upload HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Expect: 100-continue\r\n" ++
        "Content-Length: 4\r\n\r\n" ++
        "data";
    const head_len = std.mem.indexOf(u8, request, "\r\n\r\n").? + 4;
    var fake: FakeSession = .{ .child_input = request };

    const parsed = relayHead(&fake, .{
        .from = .child,
        .to = .origin,
        .is_response = false,
        .response_to_head = false,
    }).?;

    try std.testing.expectEqual(head_len, fake.child_offset);
    try std.testing.expectEqualStrings(request[0..head_len], fake.originOutput());
    try std.testing.expect(parsed.framing.hasBody());

    try std.testing.expect(relayBody(
        &fake,
        .{ .from = .child, .to = .origin, .framing = parsed.framing },
        IgnoreTestObserver{},
    ));
    try std.testing.expectEqualStrings(request, fake.originOutput());
}

test "transformed head selection is the only head written" {
    const AddHeader = struct {
        fn apply(_: *anyopaque, transformation: TransformationType) middleware.TransformStatus {
            transformation.effects.set(.{ .name = "x-telar", .value = "enabled" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = AddHeader.apply });
    const request = "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata";
    var fake: FakeSession = .{ .child_input = request };

    const parsed = relayHeadTransformed(&fake, .{
        .route = .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
        },
        .pipeline = &pipeline,
        .io = std.testing.io,
        .context = undefined,
    }).?;

    try std.testing.expectEqualDeep(types.BodyPlan{ .content_length = 4 }, parsed.framing);
    try std.testing.expect(std.mem.indexOf(u8, fake.originOutput(), "x-telar: enabled\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fake.originOutput(), "POST /upload"));
}

test "a preserved transformation forwards the original head exactly" {
    const NoEffects = struct {
        fn apply(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = NoEffects.apply });
    const request = "GET / HTTP/1.1\r\nhOsT:\texample.test\r\nX-Duplicate: one\r\nX-Duplicate: two\r\n\r\n";
    var fake: FakeSession = .{ .child_input = request };

    _ = relayHeadTransformed(&fake, .{
        .route = .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
        },
        .pipeline = &pipeline,
        .io = std.testing.io,
        .context = undefined,
    }).?;

    try std.testing.expectEqualStrings(request, fake.originOutput());
}

test "informational response is delimited before the final response" {
    const responses = "HTTP/1.1 100 Continue\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    var fake: FakeSession = .{ .origin_input = responses };

    const route: MessageRouteType = .{
        .from = .origin,
        .to = .child,
        .is_response = true,
        .response_to_head = false,
    };
    const informational = relay(&fake, route, IgnoreTestObserver{}).?;
    const final = relay(&fake, route, IgnoreTestObserver{}).?;

    try std.testing.expect(informational.informational);
    try std.testing.expectEqual(@as(u16, 200), final.status_code);
    try std.testing.expectEqualStrings(responses, fake.childOutput());
}

const integration_exchange_port: GenericExchangePort(ConnectionIntegration) = .{
    .io = ConnectionIntegration.io,
    .relay_body = ConnectionIntegration.relayRequestBody,
    .relay_response = ConnectionIntegration.relayResponse,
};

pub const IntegrationExchange = GenericExchange(ConnectionIntegration, integration_exchange_port);

const integration_connection_port: GenericPort(ConnectionIntegration) = .{
    .read_request = ConnectionIntegration.readRequest,
    .exchange = ConnectionIntegration.exchange,
    .publish_request = ConnectionIntegration.publishRequest,
    .publish_response = ConnectionIntegration.publishResponse,
    .publish_failure = ConnectionIntegration.publishFailure,
    .upgrade = ConnectionIntegration.upgrade,
};

const IntegrationConnection = GenericConnection(ConnectionIntegration, integration_connection_port);

test "HTTP connection composition relays keep-alive exchanges and publishes final results" {
    const requests = "POST /v1/messages HTTP/1.1\r\nHost: example.test\r\nContent-Length: 0\r\n\r\n" ++
        "GET /health HTTP/1.1\r\nHost: example.test\r\n\r\n";
    const responses = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ++
        "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 3\r\n\r\nbad";
    var context: ConnectionIntegration = .{
        .session = .{
            .child_input = requests,
            .origin_input = responses,
        },
    };

    IntegrationConnection.run(&context);

    try std.testing.expectEqualStrings(requests, context.session.originOutput());
    try std.testing.expectEqualStrings(responses, context.session.childOutput());
    try std.testing.expectEqualSlices(provider.RequestClass, &.{ .inference, .auxiliary }, context.request_classes[0..context.request_count]);
    try std.testing.expectEqualSlices(u16, &.{ 200, 404 }, context.response_statuses[0..context.response_count]);
    try std.testing.expectEqual(@as(usize, 0), context.failure_count);
    try std.testing.expect(!context.upgraded);
}

test {
    std.testing.refAllDecls(connection);
    std.testing.refAllDecls(head);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(body);
    std.testing.refAllDecls(types);
}
