//! Streaming relay for HTTP/1.1 message bodies.
//!
//! The relay preserves wire bytes exactly. It uses the framing already derived
//! from the head and keeps all buffers fixed-size.

const std = @import("std");
const head = @import("head.zig");
const tls = @import("../tls.zig");

pub const max_chunk_line_bytes = 128;

/// Relays one body according to `framing` and reports forwarded body activity.
///
/// The callback receives the byte count from each forwarded payload read. For
/// chunked messages this preserves the existing contract: chunk data and its
/// trailing CRLF count as activity, while size lines and trailers do not.
pub fn relay(session: anytype, from: tls.Session.Side, to: tls.Session.Side, framing: head.Framing, context: anytype, comptime activity: fn (@TypeOf(context), usize) void) bool {
    return switch (framing) {
        .none => true,
        .length => |len| relayExact(session, from, to, len, context, activity),
        .chunked => relayChunked(session, from, to, context, activity),
        .until_close => relayUntilClose(session, from, to, context, activity),
    };
}

fn relayUntilClose(session: anytype, from: tls.Session.Side, to: tls.Session.Side, context: anytype, comptime activity: fn (@TypeOf(context), usize) void) bool {
    var buffer: [16 * 1024]u8 = undefined;
    while (session.read(from, &buffer)) |len| {
        if (!session.writeAll(to, buffer[0..len])) return false;
        activity(context, len);
    }
    return true;
}

fn relayExact(session: anytype, from: tls.Session.Side, to: tls.Session.Side, count: usize, context: anytype, comptime activity: fn (@TypeOf(context), usize) void) bool {
    var left = count;
    var buffer: [16 * 1024]u8 = undefined;
    while (left != 0) {
        const len = session.read(from, buffer[0..@min(left, buffer.len)]) orelse return false;
        if (!session.writeAll(to, buffer[0..len])) return false;
        activity(context, len);
        left -= len;
    }
    return true;
}

fn relayChunked(session: anytype, from: tls.Session.Side, to: tls.Session.Side, context: anytype, comptime activity: fn (@TypeOf(context), usize) void) bool {
    var line: [max_chunk_line_bytes]u8 = undefined;
    while (true) {
        const line_len = relayLine(session, from, to, &line) orelse return false;
        const trimmed = std.mem.trim(u8, line[0..line_len], " \t\r\n");
        const extension = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const chunk_len = std.fmt.parseInt(usize, trimmed[0..extension], 16) catch return false;
        if (chunk_len == 0) return relayTrailers(session, from, to, &line);
        if (!relayExact(session, from, to, chunk_len + 2, context, activity)) return false;
    }
}

fn relayTrailers(session: anytype, from: tls.Session.Side, to: tls.Session.Side, line: []u8) bool {
    while (true) {
        const len = relayLine(session, from, to, line) orelse return false;
        if (len == 2 and std.mem.eql(u8, line[0..2], "\r\n")) return true;
    }
}

fn relayLine(session: anytype, from: tls.Session.Side, to: tls.Session.Side, buffer: []u8) ?usize {
    var len: usize = 0;
    while (len < buffer.len) {
        const read_len = session.read(from, buffer[len..][0..1]) orelse return null;
        if (read_len != 1 or !session.writeAll(to, buffer[len..][0..1])) return null;
        len += 1;
        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) return len;
    }
    return null;
}

const Activity = struct {
    bytes: usize = 0,
    calls: usize = 0,

    fn record(activity: *Activity, bytes: usize) void {
        activity.bytes += bytes;
        activity.calls += 1;
    }
};

test "a body without framing consumes and forwards nothing" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .child_input = "untouched" };
    var activity: Activity = .{};

    try std.testing.expect(relay(
        &fake,
        .child,
        .origin,
        .none,
        &activity,
        Activity.record,
    ));
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
        .child,
        .origin,
        .{ .length = 4 },
        &activity,
        Activity.record,
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
        .child,
        .origin,
        .{ .length = 4 },
        &activity,
        Activity.record,
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
        .origin,
        .child,
        .until_close,
        &activity,
        Activity.record,
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
        .origin,
        .child,
        .chunked,
        &activity,
        Activity.record,
    ));
    try std.testing.expectEqual(encoded.len, fake.origin_offset);
    try std.testing.expectEqualStrings(encoded, fake.childOutput());
    try std.testing.expectEqual(@as(usize, 13), activity.bytes);
}

test "an invalid chunk size reports failure after forwarding its line" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var fake: FakeSession = .{ .origin_input = "not-hex\r\n" };
    var activity: Activity = .{};

    try std.testing.expect(!relay(
        &fake,
        .origin,
        .child,
        .chunked,
        &activity,
        Activity.record,
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
        .origin,
        .child,
        .chunked,
        &activity,
        Activity.record,
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
        .origin,
        .child,
        .chunked,
        &activity,
        Activity.record,
    ));
    try std.testing.expectEqualStrings(encoded, fake.childOutput());
}
