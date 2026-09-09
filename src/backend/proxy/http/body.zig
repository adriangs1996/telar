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
    /// Framing bytes written ahead of the first data read, in the same
    /// record.
    prefix: []const u8 = "",
};

/// One CRLF-terminated line read without writing, plus the framing bytes
/// still held back that must precede it if consumed bytes are forwarded on
/// failure.
const LineRead = struct {
    buffer: []u8,
    held: []const u8,
};

const Partial = struct {
    held: []const u8,
    partial: []const u8,
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

/// Forwards `exact.count` bytes; the first write also carries `exact.prefix`,
/// so chunk framing leaves in the same TLS record as the data it frames.
fn relayExact(session: anytype, exact: Exact, observer: anytype) bool {
    var left = exact.count;
    var buffer: [16 * 1024]u8 = undefined;
    std.debug.assert(exact.prefix.len < buffer.len);
    var lead = exact.prefix.len;
    @memcpy(buffer[0..lead], exact.prefix);

    while (left != 0) {
        const len = session.read(exact.direction.from, buffer[lead..][0..@min(left, buffer.len - lead)]) orelse {
            if (lead != 0) {
                _ = session.writeAll(exact.direction.to, buffer[0..lead]);
            }
            return false;
        };

        if (!session.writeAll(exact.direction.to, buffer[0 .. lead + len])) {
            return false;
        }

        observer.observe(.{
            .payload = if (exact.payload) buffer[lead..][0..len] else "",
            .forwarded_bytes = len,
        });
        left -= len;
        lead = 0;
    }

    return true;
}

/// A chunk's trailing CRLF and the next size line are held back and written
/// with the following data, so one chunk costs one record instead of three.
const Framing = struct {
    bytes: [2 + max_chunk_line_bytes]u8 = undefined,
    len: usize = 0,
    /// The held bytes start with a chunk's trailing CRLF, which counts as
    /// forwarded body activity once written.
    carried_crlf: bool = false,

    fn slice(pending: *const Framing) []const u8 {
        return pending.bytes[0..pending.len];
    }

    fn append(pending: *Framing, bytes: []const u8) void {
        @memcpy(pending.bytes[pending.len..][0..bytes.len], bytes);
        pending.len += bytes.len;
    }

    fn observeCrlf(pending: *Framing, observer: anytype) void {
        if (pending.carried_crlf) {
            observer.observe(.{ .payload = "", .forwarded_bytes = 2 });
        }
        pending.* = .{};
    }
};

fn relayChunked(session: anytype, direction: Direction, observer: anytype) bool {
    var line: [max_chunk_line_bytes]u8 = undefined;
    var pending: Framing = .{};

    while (true) {
        const line_len = readLine(session, direction, .{ .buffer = &line, .held = pending.slice() }) orelse return false;
        const trimmed = std.mem.trim(u8, line[0..line_len], " \t\r\n");
        const extension = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        pending.append(line[0..line_len]);
        const chunk_len = std.fmt.parseInt(usize, trimmed[0..extension], 16) catch {
            _ = session.writeAll(direction.to, pending.slice());
            return false;
        };

        if (chunk_len == 0) {
            if (!session.writeAll(direction.to, pending.slice())) {
                return false;
            }
            pending.observeCrlf(observer);
            return relayTrailers(session, direction, &line);
        }

        if (!relayExact(session, .{
            .direction = direction,
            .count = chunk_len,
            .payload = true,
            .prefix = pending.slice(),
        }, observer)) {
            return false;
        }
        pending.observeCrlf(observer);

        // The CRLF after the data travels with the next size line.
        var crlf: [2]u8 = undefined;
        var read_len: usize = 0;
        while (read_len < crlf.len) {
            const len = session.read(direction.from, crlf[read_len..]) orelse {
                if (read_len != 0) {
                    _ = session.writeAll(direction.to, crlf[0..read_len]);
                }
                return false;
            };
            read_len += len;
        }
        pending.append(&crlf);
        pending.carried_crlf = true;
    }
}

/// Reads one CRLF-terminated line without writing it. On failure the held
/// framing and the partial line are forwarded so consumed bytes never vanish.
fn readLine(session: anytype, direction: Direction, read: LineRead) ?usize {
    const buffer = read.buffer;
    var len: usize = 0;

    while (len < buffer.len) {
        const read_len = session.read(direction.from, buffer[len..][0..1]) orelse {
            forwardPartial(session, direction, .{ .held = read.held, .partial = buffer[0..len] });
            return null;
        };

        if (read_len != 1) {
            forwardPartial(session, direction, .{ .held = read.held, .partial = buffer[0..len] });
            return null;
        }

        len += 1;

        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) {
            return len;
        }
    }

    // Preserve the consumed prefix even when framing fails at its bound.
    forwardPartial(session, direction, .{ .held = read.held, .partial = buffer[0..len] });
    return null;
}

fn forwardPartial(session: anytype, direction: Direction, bytes: Partial) void {
    var joined: [2 + 2 * max_chunk_line_bytes]u8 = undefined;
    @memcpy(joined[0..bytes.held.len], bytes.held);
    @memcpy(joined[bytes.held.len..][0..bytes.partial.len], bytes.partial);
    const total = bytes.held.len + bytes.partial.len;
    if (total != 0) {
        _ = session.writeAll(direction.to, joined[0..total]);
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
        const read_len = session.read(direction.from, buffer[len..][0..1]) orelse {
            if (len != 0) {
                _ = session.writeAll(direction.to, buffer[0..len]);
            }

            return null;
        };

        if (read_len != 1) {
            return null;
        }

        len += 1;

        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) {
            return if (session.writeAll(direction.to, buffer[0..len])) len else null;
        }
    }

    // Preserve the consumed prefix even when framing fails at its bound.
    _ = session.writeAll(direction.to, buffer[0..len]);
    return null;
}

test "chunk framing shares a write with its data and preserves single-byte input boundaries" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const encoded = "1\r\nx\r\n0\r\n\r\n";
    var fake: FakeSession = .{ .origin_input = encoded, .max_read_bytes = 1 };
    var activity: Activity = .{};
    try std.testing.expect(relay(&fake, testRoute(.origin, .child, .chunked), &activity));
    try std.testing.expectEqualStrings(encoded, fake.childOutput());
    // Size line with its data, the carried CRLF with the last-chunk line,
    // and the trailer terminator: three records for the whole body.
    try std.testing.expectEqual(@as(usize, 3), fake.write_calls);
    try std.testing.expectEqualStrings("x", activity.payload[0..activity.payload_len]);

    for (0..3) |failure| {
        fake = .{ .origin_input = encoded, .max_read_bytes = 1, .fail_write_at = failure };
        activity = .{};
        try std.testing.expect(!relay(&fake, testRoute(.origin, .child, .chunked), &activity));
        try std.testing.expectEqual(failure + 1, fake.write_calls);
    }
}

test "an incomplete chunk line forwards its prefix once" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .origin_input = "123\r" };
    var activity: Activity = .{};
    try std.testing.expect(!relay(&fake, testRoute(.origin, .child, .chunked), &activity));
    try std.testing.expectEqualStrings("123\r", fake.childOutput());
    try std.testing.expectEqual(@as(usize, 1), fake.write_calls);
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
