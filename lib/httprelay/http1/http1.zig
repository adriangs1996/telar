//! Public HTTP/1.1 relay for intercepted TLS streams.
//!
//! `connection.zig` owns exchange ordering and connection policy. `head.zig`
//! reads and analyzes heads, and `body.zig` relays bodies without changing
//! their wire representation.

const head = @import("head_support.zig");
const observer_hooks = @import("../observer_hooks.zig");
pub const body = @import("body.zig");
const types = @import("types.zig");
const connection = @import("connection.zig");
pub const GenericExchange = @import("GenericExchange.zig").Type;
pub const GenericConnection = @import("GenericConnection.zig").Type;

pub const max_chunk_line_bytes = body.max_chunk_line_bytes;
pub const max_trailer_line_bytes = body.max_trailer_line_bytes;
pub const FramingLine = @import("FramingLine.zig").FramingLine;
/// The longest head the relay reads.
pub const max_head_bytes = head.max_bytes;
pub const Fragment = @import("Fragment.zig");
pub const Message = @import("Message.zig");
pub const Framing = types.BodyPlan;
pub const Head = @import("Head.zig");
pub const BodyRoute = @import("Route.zig");
pub const BodyPlan = types.BodyPlan;
pub const ResponseContext = types.ResponseContext;
pub const ResponseKind = types.ResponseKind;
pub const ConnectionPolicy = types.ConnectionPolicy;
pub const RequestHead = @import("RequestHead.zig");
pub const ResponseHead = @import("ResponseHead.zig");
pub const ExchangeOutcome = connection.ExchangeOutcome;

pub const MessageRoute = @import("MessageRoute.zig");

/// Relays one complete HTTP/1.1 message and returns its metadata. The
/// observer sees the head bytes as read and every forwarded body fragment.
///
/// ```zig
/// const message = relay(session, route, &observer);
/// ```
pub fn relay(session: anytype, route: MessageRoute, observer: anytype) ?Message {
    const parsed = relayHead(session, route, observer) orelse return null;

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
/// concurrently for `Expect: 100-continue` and early final responses. The
/// observer's `head` receives the head bytes as read. An observer that
/// declares `headStarted()` hears the head's first byte arrive, and one that
/// declares `headTooLarge()` hears when a head passes `max_head_bytes`;
/// nothing of it was forwarded.
///
/// ```zig
/// const head = relayHead(session, route, &observer);
/// ```
pub fn relayHead(session: anytype, route: MessageRoute, observer: anytype) ?Head {
    var buffer: [head.max_bytes]u8 = undefined;
    const len = switch (head.read(session, route.from, &buffer, observer)) {
        .complete => |len| len,
        .ended => return null,
        .too_large => {
            if (comptime observer_hooks.declares(@TypeOf(observer), "headTooLarge")) {
                observer.headTooLarge();
            }

            return null;
        },
    };
    observer.head(buffer[0..len]);

    if (!session.writeAll(route.to, buffer[0..len])) {
        return null;
    }

    return head.analyze(buffer[0..len], .{
        .is_response = route.is_response,
        .response_to_head = route.response_to_head,
        .watched_routes = route.watched_routes,
    });
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
