//! Public HTTP/1.1 relay for intercepted TLS streams.
//!
//! This module owns operation ordering and transport failure policy. `head.zig`
//! reads and analyzes heads, `transform.zig` chooses whether to rewrite them,
//! and `body.zig` relays bodies without changing their wire representation.

const std = @import("std");
const body = @import("body.zig");
const head = @import("head.zig");
const transform = @import("transform.zig");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");

pub const max_head_bytes = head.max_bytes;
pub const max_chunk_line_bytes = body.max_chunk_line_bytes;
pub const Message = head.Message;
pub const Framing = head.Framing;
pub const Head = head.Head;
pub const BodyFragment = body.Fragment;
pub const BodyRoute = body.Route;

pub const MessageRoute = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
    is_response: bool,
    response_to_head: bool,
};

pub const HeadTransform = struct {
    route: MessageRoute,
    pipeline: *const middleware.TransformPipeline,
    io: std.Io,
    context: middleware.TransformContext,
};

/// Relays one complete HTTP/1.1 message and returns its metadata.
///
/// ```zig
/// const message = relay(session, route, &observer);
/// ```
pub fn relay(session: anytype, route: MessageRoute, observer: anytype) ?Message {
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
pub fn relayHead(session: anytype, route: MessageRoute) ?Head {
    var buffer: [max_head_bytes]u8 = undefined;
    const len = head.read(session, route.from, &buffer) orelse return null;

    if (!session.writeAll(route.to, buffer[0..len])) {
        return null;
    }

    return head.analyze(buffer[0..len], route.is_response, route.response_to_head);
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
pub fn relayHeadTransformed(session: anytype, transformation: HeadTransform) ?Head {
    if (transformation.pipeline.len == 0) {
        return relayHead(session, transformation.route);
    }

    var original: [max_head_bytes]u8 = undefined;
    const original_len = head.read(session, transformation.route.from, &original) orelse return null;
    const original_head = head.analyze(
        original[0..original_len],
        transformation.route.is_response,
        transformation.route.response_to_head,
    ) orelse return null;

    var encoded: [max_head_bytes]u8 = undefined;
    var selected_head = original_head;
    const selected_bytes = switch (transform.decide(
        original[0..original_len],
        original_head,
        transformation.route.is_response,
        transformation.route.response_to_head,
        transformation.pipeline,
        transformation.io,
        transformation.context,
        &encoded,
    )) {
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
pub fn relayBody(session: anytype, route: BodyRoute, observer: anytype) bool {
    return body.relay(session, route, observer);
}

const FakeSession = @import("test_support.zig").FakeSession;

const IgnoreTestObserver = struct {
    pub fn observe(_: IgnoreTestObserver, _: BodyFragment) void {}
};

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
        fn apply(
            _: *anyopaque,
            _: std.Io,
            _: middleware.HeaderSnapshot,
            effects: *middleware.EffectBatch,
        ) middleware.TransformStatus {
            effects.set("x-telar", "enabled", false) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
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

    try std.testing.expectEqualDeep(Framing{ .length = 4 }, parsed.framing);
    try std.testing.expect(std.mem.indexOf(u8, fake.originOutput(), "x-telar: enabled\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fake.originOutput(), "POST /upload"));
}

test "a preserved transformation forwards the original head exactly" {
    const NoEffects = struct {
        fn apply(
            _: *anyopaque,
            _: std.Io,
            _: middleware.HeaderSnapshot,
            _: *middleware.EffectBatch,
        ) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
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

    const route: MessageRoute = .{
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

test {
    std.testing.refAllDecls(head);
    std.testing.refAllDecls(transform);
    std.testing.refAllDecls(body);
}
