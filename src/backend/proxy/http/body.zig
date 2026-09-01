//! Streaming relay for HTTP/1.1 message bodies.
//!
//! The relay preserves wire bytes exactly. It uses the framing already derived
//! from the head and keeps all buffers fixed-size.

const std = @import("std");
const head = @import("head.zig");
const tls = @import("../tls.zig");

pub const max_chunk_line_bytes = 128;

pub const Route = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
    framing: head.Framing,
};

/// One successfully forwarded body fragment.
///
/// `payload` excludes HTTP chunk framing. `forwarded_bytes` includes bytes
/// that count as body activity, including the CRLF after chunk data.
pub const Fragment = struct {
    payload: []const u8,
    forwarded_bytes: usize,
};

/// Relays one body according to its parsed route and reports forwarded
/// fragments without giving the observer control over traffic.
///
/// The observer's `observe(Fragment)` method runs only after the corresponding
/// bytes have been written. Its return value, if any, is ignored.
///
/// ```zig
/// const route: Route = .{ .from = .origin, .to = .child, .framing = .chunked };
/// const forwarded = relay(session, route, &observer);
/// ```
pub fn relay(session: anytype, route: Route, observer: anytype) bool {
    const direction: Direction = .{ .from = route.from, .to = route.to };

    return switch (route.framing) {
        .none => true,
        .content_length => |len| relayExact(session, .{
            .direction = direction,
            .count = len,
            .payload = true,
        }, observer),
        .chunked => relayChunked(session, direction, observer),
        .until_close => relayUntilClose(session, direction, observer),
    };
}

const Direction = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
};

const Exact = struct {
    direction: Direction,
    count: usize,
    payload: bool,
};

fn relayUntilClose(session: anytype, direction: Direction, observer: anytype) bool {
    var buffer: [16 * 1024]u8 = undefined;

    while (session.read(direction.from, &buffer)) |len| {
        if (!session.writeAll(direction.to, buffer[0..len])) {
            return false;
        }

        observer.observe(.{ .payload = buffer[0..len], .forwarded_bytes = len });
    }

    return true;
}

fn relayExact(session: anytype, exact: Exact, observer: anytype) bool {
    var left = exact.count;
    var buffer: [16 * 1024]u8 = undefined;

    while (left != 0) {
        const len = session.read(exact.direction.from, buffer[0..@min(left, buffer.len)]) orelse return false;

        if (!session.writeAll(exact.direction.to, buffer[0..len])) {
            return false;
        }

        observer.observe(.{
            .payload = if (exact.payload) buffer[0..len] else "",
            .forwarded_bytes = len,
        });
        left -= len;
    }

    return true;
}

fn relayChunked(session: anytype, direction: Direction, observer: anytype) bool {
    var line: [max_chunk_line_bytes]u8 = undefined;

    while (true) {
        const line_len = relayLine(session, direction, &line) orelse return false;
        const trimmed = std.mem.trim(u8, line[0..line_len], " \t\r\n");
        const extension = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const chunk_len = std.fmt.parseInt(usize, trimmed[0..extension], 16) catch return false;

        if (chunk_len == 0) {
            return relayTrailers(session, direction, &line);
        }

        if (!relayExact(session, .{
            .direction = direction,
            .count = chunk_len,
            .payload = true,
        }, observer)) {
            return false;
        }

        if (!relayExact(session, .{
            .direction = direction,
            .count = 2,
            .payload = false,
        }, observer)) {
            return false;
        }
    }
}

fn relayTrailers(session: anytype, direction: Direction, line: []u8) bool {
    while (true) {
        const len = relayLine(session, direction, line) orelse return false;

        if (len == 2 and std.mem.eql(u8, line[0..2], "\r\n")) {
            return true;
        }
    }
}

fn relayLine(session: anytype, direction: Direction, buffer: []u8) ?usize {
    var len: usize = 0;

    while (len < buffer.len) {
        const read_len = session.read(direction.from, buffer[len..][0..1]) orelse return null;

        if (read_len != 1 or !session.writeAll(direction.to, buffer[len..][0..1])) {
            return null;
        }

        len += 1;

        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) {
            return len;
        }
    }

    return null;
}

const Activity = struct {
    bytes: usize = 0,
    calls: usize = 0,
    payload: [64]u8 = undefined,
    payload_len: usize = 0,

    fn observe(activity: *Activity, fragment: Fragment) void {
        activity.bytes += fragment.forwarded_bytes;
        activity.calls += 1;

        @memcpy(activity.payload[activity.payload_len..][0..fragment.payload.len], fragment.payload);
        activity.payload_len += fragment.payload.len;
    }
};

fn testRoute(from: tls.Session.Side, to: tls.Session.Side, framing: head.Framing) Route {
    return .{ .from = from, .to = to, .framing = framing };
}

test "a body without framing consumes and forwards nothing" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .child_input = "untouched" };
    var activity: Activity = .{};

    try std.testing.expect(relay(&fake, testRoute(.child, .origin, .none), &activity));
    try std.testing.expectEqual(@as(usize, 0), fake.child_offset);
    try std.testing.expectEqualStrings("", fake.originOutput());
    try std.testing.expectEqual(@as(usize, 0), activity.bytes);
}

test "a fixed body stops at its declared length across short reads" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{
        .child_input = "bodyNEXT",
        .max_read_bytes = 2,
    };
    var activity: Activity = .{};

    try std.testing.expect(relay(
        &fake,
        testRoute(.child, .origin, .{ .content_length = 4 }),
        &activity,
    ));
    try std.testing.expectEqual(@as(usize, 4), fake.child_offset);
    try std.testing.expectEqualStrings("body", fake.originOutput());
    try std.testing.expectEqual(@as(usize, 4), activity.bytes);
    try std.testing.expectEqual(@as(usize, 2), activity.calls);
}

test "an incomplete fixed body reports failure after forwarding its prefix" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .child_input = "ab" };
    var activity: Activity = .{};

    try std.testing.expect(!relay(
        &fake,
        testRoute(.child, .origin, .{ .content_length = 4 }),
        &activity,
    ));
    try std.testing.expectEqualStrings("ab", fake.originOutput());
    try std.testing.expectEqual(@as(usize, 2), activity.bytes);
}

test "a close-delimited body relays until EOF" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{
        .origin_input = "streamed response",
        .max_read_bytes = 3,
    };
    var activity: Activity = .{};

    try std.testing.expect(relay(
        &fake,
        testRoute(.origin, .child, .until_close),
        &activity,
    ));
    try std.testing.expectEqualStrings("streamed response", fake.childOutput());
    try std.testing.expectEqual(@as(usize, "streamed response".len), activity.bytes);
}

test "a chunked body preserves chunk framing and trailers" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const encoded = "4;extension=yes\r\nWiki\r\n" ++
        "5\r\npedia\r\n" ++
        "0\r\nX-Trace: present\r\n\r\n";
    var fake: FakeSession = .{
        .origin_input = encoded ++ "NEXT",
        .max_read_bytes = 2,
    };
    var activity: Activity = .{};

    try std.testing.expect(relay(
        &fake,
        testRoute(.origin, .child, .chunked),
        &activity,
    ));
    try std.testing.expectEqual(encoded.len, fake.origin_offset);
    try std.testing.expectEqualStrings(encoded, fake.childOutput());
    try std.testing.expectEqual(@as(usize, 13), activity.bytes);
    try std.testing.expectEqualStrings("Wikipedia", activity.payload[0..activity.payload_len]);
}

test "an invalid chunk size reports failure after forwarding its line" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .origin_input = "not-hex\r\n" };
    var activity: Activity = .{};

    try std.testing.expect(!relay(
        &fake,
        testRoute(.origin, .child, .chunked),
        &activity,
    ));
    try std.testing.expectEqualStrings("not-hex\r\n", fake.childOutput());
    try std.testing.expectEqual(@as(usize, 0), activity.bytes);
}

test "an oversized chunk line reports failure at its bound" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const input: [max_chunk_line_bytes + 2]u8 = @splat('f');
    var fake: FakeSession = .{ .origin_input = &input };
    var activity: Activity = .{};

    try std.testing.expect(!relay(
        &fake,
        testRoute(.origin, .child, .chunked),
        &activity,
    ));
    try std.testing.expectEqual(max_chunk_line_bytes, fake.origin_offset);
    try std.testing.expectEqual(max_chunk_line_bytes, fake.childOutput().len);
}

test "an incomplete trailer block reports failure" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const encoded = "0\r\nX-Trace: incomplete\r\n";
    var fake: FakeSession = .{ .origin_input = encoded };
    var activity: Activity = .{};

    try std.testing.expect(!relay(
        &fake,
        testRoute(.origin, .child, .chunked),
        &activity,
    ));
    try std.testing.expectEqualStrings(encoded, fake.childOutput());
}
