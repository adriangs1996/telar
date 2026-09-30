//! Bounded reading and semantic analysis of HTTP/1.1 heads.
//!
//! `read` stops at the first `CRLF CRLF` boundary without consuming body bytes.
//! `analyze` derives message and body-framing metadata without retaining slices
//! into the input.

const types = @import("types.zig");
const localca = @import("localca");
const Session = localca.Session;
const std = @import("std");
const header_rules = @import("../header_rules.zig");
const observer_hooks = @import("../observer_hooks.zig");
const RouteMatch = @import("../RouteMatch.zig");
const FakeSessionType = @import("FakeSession.zig");

/// The longest head the relay reads: request lines, large cookies and
/// bearer tokens fit, as in common servers.
pub const max_bytes = 64 * 1024;

pub const Message = @import("Message.zig");

pub const Framing = types.BodyPlan;

pub const Head = @import("Head.zig");

pub const AnalyzeOptions = @import("AnalyzeOptions.zig");

/// Reads one complete head into `buffer` and returns its byte length.
///
/// The function reads one byte at a time because the session has no pushback
/// buffer. This guarantees that a successful call leaves the first body byte
/// unread. It returns `.ended` on EOF or a zero-length read, and
/// `.too_large` when the buffer fills before the head ends. An observer that
/// declares `headStarted()` hears the first byte arrive.
///
/// ```zig
/// const head_len = switch (read(session, .child, &buffer, &observer)) {
///     .complete => |len| len,
///     .ended, .too_large => return,
/// };
/// ```
pub fn read(session: anytype, side: Session.Side, buffer: []u8, observer: anytype) HeadRead {
    var len: usize = 0;
    while (len < buffer.len) {
        const read_len = session.read(side, buffer[len..][0..1]) orelse return .ended;
        if (read_len != 1) {
            return .ended;
        }

        if (len == 0 and comptime observer_hooks.declares(@TypeOf(observer), "headStarted")) {
            observer.headStarted();
        }

        len += 1;
        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) {
            return .{
                .complete = len,
            };
        }
    }

    return .too_large;
}

/// What reading one head found.
pub const HeadRead = union(enum) {
    /// A whole head of this many bytes.
    complete: usize,
    /// The stream ended first.
    ended,
    /// The buffer filled before the head ended.
    too_large,
};

/// Derives message and framing metadata from one complete HTTP/1.1 head.
///
/// `options.response_to_head` identifies a response to a `HEAD` request. Such
/// a response has no body even when its headers describe the body a `GET`
/// would have returned. `watched` compares the original, untransformed start
/// line with the caller's watched routes.
/// Invalid or ambiguous framing returns `null`.
///
/// ```zig
/// const parsed = analyze(bytes, .{
///     .is_response = false,
///     .response_to_head = false,
///     .watched_routes = &inference_routes,
/// });
/// ```
pub fn analyze(bytes: []const u8, options: AnalyzeOptions) ?Head {
    const first_line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
    const start_line = bytes[0..first_line_end];
    const status_code: u16 = if (options.is_response) parseStatus(start_line) orelse return null else 0;
    const bodyless = options.is_response and (options.response_to_head or
        (status_code >= 100 and status_code < 200) or
        status_code == 204 or status_code == 205 or status_code == 304);
    const framing = framingOf(bytes, options.is_response, bodyless) orelse return null;

    return .{
        .message = .{
            .status_code = status_code,
            .head_request = !options.is_response and isHeadRequest(start_line),
            .informational = options.is_response and status_code >= 100 and status_code < 200 and
                status_code != 101,
            .upgrade = options.is_response and status_code == 101,
            .closes = switch (framing) {
                .until_close => true,
                else => connectionCloses(bytes),
            },
        },
        .framing = framing,
        .watched = !options.is_response and watchedRequest(start_line, options.watched_routes),
        .sse_body = options.is_response and hasObservableSseBody(bytes),
    };
}

fn hasObservableSseBody(bytes: []const u8) bool {
    var event_stream = false;
    var content_type_seen = false;
    var identity_encoding = true;
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            if (content_type_seen) {
                return false;
            }

            content_type_seen = true;
            event_stream = header_rules.isEventStreamContentType(value);
        }

        if (std.ascii.eqlIgnoreCase(name, "content-encoding") and !header_rules.isIdentityContentEncoding(value)) {
            identity_encoding = false;
        }

        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and !onlyChunkedCoding(value)) {
            identity_encoding = false;
        }
    }

    return content_type_seen and event_stream and identity_encoding;
}

fn onlyChunkedCoding(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    const coding = std.mem.trim(u8, tokens.next() orelse return false, " \t");

    return coding.len != 0 and std.ascii.eqlIgnoreCase(coding, "chunked") and tokens.next() == null;
}

fn watchedRequest(start_line: []const u8, routes: []const RouteMatch) bool {
    const method_end = std.mem.indexOfScalar(u8, start_line, ' ') orelse return false;
    const version_start = std.mem.lastIndexOfScalar(u8, start_line, ' ') orelse return false;
    if (method_end == version_start) {
        return false;
    }

    return RouteMatch.matchesAny(start_line[0..method_end], start_line[method_end + 1 .. version_start], routes);
}

fn framingOf(bytes: []const u8, is_response: bool, bodyless: bool) ?types.BodyPlan {
    if (bodyless) {
        return .none;
    }

    var transfer_encoding: ?[]const u8 = null;
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (transfer_encoding != null or value.len == 0) {
                return null;
            }
            transfer_encoding = value;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            var values = std.mem.splitScalar(u8, value, ',');
            var found = false;
            while (values.next()) |part| {
                const text = std.mem.trim(u8, part, " \t");
                if (text.len == 0) {
                    return null;
                }
                const len = std.fmt.parseInt(usize, text, 10) catch return null;
                if (content_length) |previous| {
                    if (previous != len) {
                        return null;
                    }
                } else {
                    content_length = len;
                }
                found = true;
            }
            if (!found) {
                return null;
            }
        }
    }

    if (transfer_encoding) |value| {
        if (content_length != null) {
            return null;
        }
        if (lastTokenEquals(value, "chunked")) {
            return .chunked;
        }
        return if (is_response) .until_close else null;
    }
    if (content_length) |len| {
        return .{ .content_length = len };
    }
    return if (is_response) .until_close else .none;
}

fn connectionCloses(bytes: []const u8) bool {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "connection") and
            containsToken(std.mem.trim(u8, line[colon + 1 ..], " \t"), "close"))
        {
            return true;
        }
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
        if (trimmed.len == 0) {
            return false;
        }
        last = trimmed;
    }
    return if (last) |token| std.ascii.eqlIgnoreCase(token, wanted) else false;
}

fn isHeadRequest(line: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    return std.mem.eql(u8, line[0..end], "HEAD");
}

fn parseStatus(line: []const u8) ?u16 {
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next();
    const text = parts.next() orelse return null;

    if (text.len != 3) {
        return null;
    }

    const status = std.fmt.parseInt(u16, text, 10) catch return null;

    return if (status >= 100 and status <= 599) status else null;
}

/// The routes the tests watch.
const test_routes = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/messages"} }};

fn analyzeRequest(bytes: []const u8, routes: []const RouteMatch) ?Head {
    return analyze(bytes, .{
        .is_response = false,
        .response_to_head = false,
        .watched_routes = routes,
    });
}

fn analyzeResponse(bytes: []const u8, response_to_head: bool) ?Head {
    return analyze(bytes, .{
        .is_response = true,
        .response_to_head = response_to_head,
    });
}

test "head reader stops before the first body byte" {
    const FakeSession = FakeSessionType;
    const input = "POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\ndata";
    const expected_len = std.mem.indexOf(u8, input, "\r\n\r\n").? + 4;
    var fake: FakeSession = .{ .child_input = input };
    var buffer: [max_bytes]u8 = undefined;

    const len = read(&fake, .child, &buffer, {}).complete;

    try std.testing.expectEqual(expected_len, len);
    try std.testing.expectEqual(expected_len, fake.child_offset);
    try std.testing.expectEqualStrings(input[0..expected_len], buffer[0..len]);
}

test "head reader tells an observer that asks when the first byte arrives" {
    const FakeSession = FakeSessionType;
    var fake: FakeSession = .{
        .child_input = "GET / HTTP/1.1\r\n\r\n",
    };
    var buffer: [max_bytes]u8 = undefined;
    var watcher: StartWatcher = .{};

    _ = read(&fake, .child, &buffer, &watcher);
    try std.testing.expectEqual(@as(usize, 1), watcher.started);
}

/// Counts the heads whose first byte arrived.
const StartWatcher = struct {
    started: usize = 0,

    pub fn headStarted(self: *StartWatcher) void {
        self.started += 1;
    }
};

test "head reader rejects EOF before the blank line" {
    const FakeSession = FakeSessionType;
    const input = "GET / HTTP/1.1\r\nHost: example.test\r\n";
    var fake: FakeSession = .{ .child_input = input };
    var buffer: [max_bytes]u8 = undefined;

    try std.testing.expectEqual(HeadRead.ended, read(&fake, .child, &buffer, {}));
    try std.testing.expectEqual(input.len, fake.child_offset);
}

test "head reader rejects a head that fills its bound" {
    const FakeSession = FakeSessionType;
    var input: [max_bytes]u8 = @splat('x');
    var fake: FakeSession = .{ .child_input = &input };
    var buffer: [max_bytes]u8 = undefined;

    try std.testing.expectEqual(HeadRead.too_large, read(&fake, .child, &buffer, {}));
    try std.testing.expectEqual(max_bytes, fake.child_offset);
}

test "analyze recognizes fixed and chunked body framing" {
    try std.testing.expectEqualDeep(types.BodyPlan{ .content_length = 42 }, analyze(
        "POST / HTTP/1.1\r\nContent-Length: 42\r\n\r\n",
        .{ .is_response = false, .response_to_head = false },
    ).?.framing);
    try std.testing.expectEqual(types.BodyPlan.chunked, analyze(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        .{ .is_response = true, .response_to_head = false },
    ).?.framing);
}

test "analyze accepts repeated identical content lengths" {
    try std.testing.expectEqualDeep(types.BodyPlan{ .content_length = 4 }, analyze(
        "POST / HTTP/1.1\r\nContent-Length: 4, 4\r\nContent-Length: 4\r\n\r\n",
        .{ .is_response = false, .response_to_head = false },
    ).?.framing);
}

test "analyze rejects ambiguous body framing" {
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n",
        .{ .is_response = false, .response_to_head = false },
    ) == null);
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n",
        .{ .is_response = false, .response_to_head = false },
    ) == null);
    try std.testing.expect(analyze(
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        .{ .is_response = false, .response_to_head = false },
    ) == null);
}

test "responses without an explicit length close the connection" {
    const parsed = analyzeResponse("HTTP/1.1 200 OK\r\n\r\n", false).?;
    try std.testing.expectEqual(types.BodyPlan.until_close, parsed.framing);
    try std.testing.expect(parsed.message.closes);
}

test "SSE response metadata accepts identity payloads across HTTP framing modes" {
    const cases = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\ncOnTeNt-TyPe: Text/Event-Stream ; charset=utf-8\r\nContent-Encoding: identity\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
    };

    for (cases) |bytes| {
        try std.testing.expect(analyzeResponse(bytes, false).?.sse_body);
    }
}

test "SSE response metadata rejects ambiguous non-SSE and encoded payloads" {
    const cases = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Type: text/event-stream\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding:\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
    };

    for (cases) |bytes| {
        try std.testing.expect(!analyzeResponse(bytes, false).?.sse_body);
    }
}

test "request content type never assigns response SSE metadata" {
    const parsed = analyzeRequest(
        "POST /v1/messages HTTP/1.1\r\nContent-Type: text/event-stream\r\nContent-Length: 0\r\n\r\n",
        &test_routes,
    ).?;

    try std.testing.expect(!parsed.sse_body);
}

test "bodyless responses ignore declared framing" {
    inline for (.{ 100, 101, 204, 205, 304 }) |status| {
        var buffer: [96]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &buffer,
            "HTTP/1.1 {d} Status\r\nContent-Length: 42\r\n\r\n",
            .{status},
        );
        try std.testing.expectEqual(types.BodyPlan.none, analyzeResponse(bytes, false).?.framing);
    }
    try std.testing.expectEqual(types.BodyPlan.none, analyzeResponse(
        "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n",
        true,
    ).?.framing);
}

test "status and connection tokens are case insensitive" {
    const parsed = analyzeResponse(
        "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: keep-alive, Close\r\n\r\n",
        false,
    ).?;
    try std.testing.expectEqual(@as(u16, 429), parsed.message.status_code);
    try std.testing.expect(parsed.message.closes);
}

test "response status must be exactly three digits in the HTTP range" {
    const invalid = [_][]const u8{
        "HTTP/1.1 0 Invalid\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 99 Invalid\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 600 Invalid\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 0200 Invalid\r\nContent-Length: 0\r\n\r\n",
        "HTTP/1.1 two Invalid\r\nContent-Length: 0\r\n\r\n",
    };

    for (invalid) |bytes| {
        try std.testing.expect(analyzeResponse(bytes, false) == null);
    }
}

test "a request is watched when its original start line matches a watched route" {
    try std.testing.expect(analyzeRequest(
        "POST /v1/messages?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        &test_routes,
    ).?.watched);
    try std.testing.expect(!analyzeRequest(
        "POST /v1/messages HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        &.{},
    ).?.watched);
    try std.testing.expect(!analyzeRequest(
        "POST /v1/messages/count_tokens?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        &test_routes,
    ).?.watched);
    try std.testing.expect(!analyzeRequest(
        "POST /api/event_logging/v2/batch HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        &test_routes,
    ).?.watched);
}

test "a HEAD request is identified without assigning response metadata" {
    const parsed = analyzeRequest(
        "HEAD /v1/messages HTTP/1.1\r\nHost: example.test\r\n\r\n",
        &test_routes,
    ).?;
    try std.testing.expect(parsed.message.head_request);
    try std.testing.expectEqual(@as(u16, 0), parsed.message.status_code);
    try std.testing.expectEqual(types.BodyPlan.none, parsed.framing);
}

test "framing reports whether a concurrent body relay is needed" {
    try std.testing.expect(!types.BodyPlan.hasBody(.none));
    try std.testing.expect(!(types.BodyPlan{ .content_length = 0 }).hasBody());
    try std.testing.expect((types.BodyPlan{ .content_length = 1 }).hasBody());
    try std.testing.expect(types.BodyPlan.hasBody(.chunked));
    try std.testing.expect(types.BodyPlan.hasBody(.until_close));
}
