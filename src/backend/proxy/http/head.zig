//! Bounded reading and semantic analysis of HTTP/1.1 heads.
//!
//! `read` stops at the first `CRLF CRLF` boundary without consuming body bytes.
//! `analyze` derives message and body-framing metadata without retaining slices
//! into the input.

const std = @import("std");
const middleware = @import("../middleware.zig");
const tls = @import("../tls.zig");

pub const max_bytes = 32 * 1024;

pub const Message = struct {
    status_code: u16 = 0,
    head_request: bool = false,
    informational: bool = false,
    upgrade: bool = false,
    closes: bool = false,
};

pub const Framing = union(enum) {
    none,
    length: usize,
    chunked,
    until_close,

    pub fn hasBody(framing: Framing) bool {
        return switch (framing) {
            .none => false,
            .length => |len| len != 0,
            .chunked, .until_close => true,
        };
    }
};

pub const Head = struct {
    message: Message,
    framing: Framing,
    inference_request: bool,
};

/// Reads one complete head into `buffer` and returns its byte length.
///
/// The function reads one byte at a time because the session has no pushback
/// buffer. This guarantees that a successful call leaves the first body byte
/// unread. It returns `null` on EOF, a zero-length read, or an oversized head.
pub fn read(session: anytype, side: tls.Session.Side, buffer: []u8) ?usize {
    var len: usize = 0;
    while (len < buffer.len) {
        const read_len = session.read(side, buffer[len..][0..1]) orelse return null;
        if (read_len != 1) return null;
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) return len;
    }
    return null;
}

/// Derives message and framing metadata from one complete HTTP/1.1 head.
///
/// `response_to_head` identifies a response to a `HEAD` request. Such a
/// response has no body even when its headers describe the body a `GET` would
/// have returned. Invalid or ambiguous framing returns `null`.
pub fn analyze(bytes: []const u8, is_response: bool, response_to_head: bool) ?Head {
    const first_line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
    const start_line = bytes[0..first_line_end];
    const status_code = if (is_response) parseStatus(start_line) else 0;
    const bodyless = is_response and (response_to_head or
        (status_code >= 100 and status_code < 200) or
        status_code == 204 or status_code == 205 or status_code == 304);
    const framing = framingOf(bytes, is_response, bodyless) orelse return null;

    return .{
        .message = .{
            .status_code = status_code,
            .head_request = !is_response and isHeadRequest(start_line),
            .informational = is_response and status_code >= 100 and status_code < 200 and
                status_code != 101,
            .upgrade = is_response and status_code == 101,
            .closes = switch (framing) {
                .until_close => true,
                else => connectionCloses(bytes),
            },
        },
        .framing = framing,
        .inference_request = !is_response and inferenceRequest(start_line),
    };
}

fn inferenceRequest(start_line: []const u8) bool {
    const method_end = std.mem.indexOfScalar(u8, start_line, ' ') orelse return false;
    const version_start = std.mem.lastIndexOfScalar(u8, start_line, ' ') orelse return false;
    if (method_end == version_start) return false;
    return middleware.isInferenceRequest(
        start_line[0..method_end],
        start_line[method_end + 1 .. version_start],
    );
}

fn framingOf(bytes: []const u8, is_response: bool, bodyless: bool) ?Framing {
    if (bodyless) return .none;

    var transfer_encoding: ?[]const u8 = null;
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (transfer_encoding != null or value.len == 0) return null;
            transfer_encoding = value;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            var values = std.mem.splitScalar(u8, value, ',');
            var found = false;
            while (values.next()) |part| {
                const text = std.mem.trim(u8, part, " \t");
                if (text.len == 0) return null;
                const len = std.fmt.parseInt(usize, text, 10) catch return null;
                if (content_length) |previous| {
                    if (previous != len) return null;
                } else {
                    content_length = len;
                }
                found = true;
            }
            if (!found) return null;
        }
    }

    if (transfer_encoding) |value| {
        if (content_length != null) return null;
        if (lastTokenEquals(value, "chunked")) return .chunked;
        return if (is_response) .until_close else null;
    }
    if (content_length) |len| return .{ .length = len };
    return if (is_response) .until_close else .none;
}

fn connectionCloses(bytes: []const u8) bool {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "connection") and
            containsToken(std.mem.trim(u8, line[colon + 1 ..], " \t"), "close")) return true;
    }
    return false;
}

fn containsToken(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, token, " \t"),
        wanted,
    )) return true;
    return false;
}

fn lastTokenEquals(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    var last: ?[]const u8 = null;
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len == 0) return false;
        last = trimmed;
    }
    return if (last) |token| std.ascii.eqlIgnoreCase(token, wanted) else false;
}

fn isHeadRequest(line: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    return std.mem.eql(u8, line[0..end], "HEAD");
}

fn parseStatus(line: []const u8) u16 {
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    return std.fmt.parseInt(u16, parts.next() orelse return 0, 10) catch 0;
}

test "head reader stops before the first body byte" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const input = "POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\ndata";
    const expected_len = std.mem.indexOf(u8, input, "\r\n\r\n").? + 4;
    var fake: FakeSession = .{ .child_input = input };
    var buffer: [max_bytes]u8 = undefined;

    const len = read(&fake, .child, &buffer).?;

    try std.testing.expectEqual(expected_len, len);
    try std.testing.expectEqual(expected_len, fake.child_offset);
    try std.testing.expectEqualStrings(input[0..expected_len], buffer[0..len]);
}

test "head reader rejects EOF before the blank line" {
    const FakeSession = @import("test_support.zig").FakeSession;
    const input = "GET / HTTP/1.1\r\nHost: example.test\r\n";
    var fake: FakeSession = .{ .child_input = input };
    var buffer: [max_bytes]u8 = undefined;

    try std.testing.expect(read(&fake, .child, &buffer) == null);
    try std.testing.expectEqual(input.len, fake.child_offset);
}

test "head reader rejects a head that fills its bound" {
    const FakeSession = @import("test_support.zig").FakeSession;
    var input: [max_bytes]u8 = @splat('x');
    var fake: FakeSession = .{ .child_input = &input };
    var buffer: [max_bytes]u8 = undefined;

    try std.testing.expect(read(&fake, .child, &buffer) == null);
    try std.testing.expectEqual(max_bytes, fake.child_offset);
}

test "analyze recognizes fixed and chunked body framing" {
    try std.testing.expectEqualDeep(Framing{ .length = 42 }, analyze(
        "POST / HTTP/1.1\r\nContent-Length: 42\r\n\r\n",
        false,
        false,
    ).?.framing);
    try std.testing.expectEqual(Framing.chunked, analyze(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        true,
        false,
    ).?.framing);
}

test "analyze accepts repeated identical content lengths" {
    try std.testing.expectEqualDeep(Framing{ .length = 4 }, analyze(
        "POST / HTTP/1.1\r\nContent-Length: 4, 4\r\nContent-Length: 4\r\n\r\n",
        false,
        false,
    ).?.framing);
}

test "analyze rejects ambiguous body framing" {
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n",
        false,
        false,
    ) == null);
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n",
        false,
        false,
    ) == null);
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        false,
        false,
    ) == null);
}

test "responses without an explicit length close the connection" {
    const parsed = analyze("HTTP/1.1 200 OK\r\n\r\n", true, false).?;
    try std.testing.expectEqual(Framing.until_close, parsed.framing);
    try std.testing.expect(parsed.message.closes);
}

test "bodyless responses ignore declared framing" {
    inline for (.{ 100, 101, 204, 205, 304 }) |status| {
        var buffer: [96]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &buffer,
            "HTTP/1.1 {d} Status\r\nContent-Length: 42\r\n\r\n",
            .{status},
        );
        try std.testing.expectEqual(Framing.none, analyze(bytes, true, false).?.framing);
    }
    try std.testing.expectEqual(Framing.none, analyze(
        "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n",
        true,
        true,
    ).?.framing);
}

test "status and connection tokens are case insensitive" {
    const parsed = analyze(
        "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: keep-alive, Close\r\n\r\n",
        true,
        false,
    ).?;
    try std.testing.expectEqual(@as(u16, 429), parsed.message.status_code);
    try std.testing.expect(parsed.message.closes);
}

test "inference classification excludes auxiliary provider routes" {
    try std.testing.expect(analyze(
        "POST /v1/messages?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
    try std.testing.expect(!analyze(
        "POST /v1/messages/count_tokens?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
    try std.testing.expect(!analyze(
        "POST /api/event_logging/v2/batch HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
}

test "a HEAD request is identified without assigning response metadata" {
    const parsed = analyze(
        "HEAD /v1/messages HTTP/1.1\r\nHost: example.test\r\n\r\n",
        false,
        false,
    ).?;
    try std.testing.expect(parsed.message.head_request);
    try std.testing.expectEqual(@as(u16, 0), parsed.message.status_code);
    try std.testing.expectEqual(Framing.none, parsed.framing);
}

test "framing reports whether a concurrent body relay is needed" {
    try std.testing.expect(!Framing.hasBody(.none));
    try std.testing.expect(!(Framing{ .length = 0 }).hasBody());
    try std.testing.expect((Framing{ .length = 1 }).hasBody());
    try std.testing.expect(Framing.hasBody(.chunked));
    try std.testing.expect(Framing.hasBody(.until_close));
}
