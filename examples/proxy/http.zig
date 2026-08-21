const std = @import("std");
const tls = @import("tls.zig");

// HTTP/1.1 message framing over an intercepted connection.
//
// Half duplex on purpose: HTTP/1.1 is strictly request-then-response, so one
// side speaks at a time and neither `SSL` object is ever touched by two threads.
// That also makes streaming responses work — a chunked or close-delimited body
// is forwarded as it arrives, so SSE still streams.

pub const Framing = enum { length, chunked, until_close, none };

pub const Summary = struct {
    /// The full head, borrowed from the caller's scratch buffer and therefore
    /// only valid until the next `relay` call that reuses it.
    head: []const u8,
    /// First line, verbatim: "POST /v1/messages HTTP/1.1" or "HTTP/1.1 200 OK".
    start_line: []const u8,
    body_bytes: usize,
    /// Body text, truncated to the caller's budget. Auth headers never reach
    /// here — see `redactedHead`.
    body: []const u8,
    truncated: bool,
};

/// Headers whose value is a credential. Dropped before anything is recorded:
/// not redacted late, never captured at all.
const secret_headers = [_][]const u8{
    "authorization",
    "x-api-key",
    "proxy-authorization",
    "cookie",
    "set-cookie",
};

pub fn isSecretHeader(name: []const u8) bool {
    for (secret_headers) |secret| {
        if (std.ascii.eqlIgnoreCase(name, secret)) return true;
    }
    return false;
}

/// Copies `head` with every credential header's value replaced. The result is
/// what may be stored; the original is only ever forwarded on the wire.
pub fn redactedHead(head: []const u8, out: *std.Io.Writer) !void {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (isSecretHeader(std.mem.trim(u8, line[0..colon], " "))) {
                try out.print("{s}: <redacted>\n", .{line[0..colon]});
                continue;
            }
        }
        try out.print("{s}\n", .{line});
    }
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // start line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

pub fn framingOf(head: []const u8, is_response_to_head_or_204: bool) struct { Framing, usize } {
    if (is_response_to_head_or_204) return .{ .none, 0 };
    if (headerValue(head, "transfer-encoding")) |te| {
        if (std.ascii.indexOfIgnoreCase(te, "chunked") != null) return .{ .chunked, 0 };
    }
    if (headerValue(head, "content-length")) |cl| {
        const n = std.fmt.parseInt(usize, cl, 10) catch 0;
        return .{ .length, n };
    }
    return .{ .none, 0 };
}

/// Rewrites a request head so the origin answers in plain text.
///
/// Clients ask for `br, gzip, deflate`, which makes every response body a blob
/// of compressed bytes in the capture. Downgrading the request to `identity`
/// costs bandwidth and buys readability, which is the entire point of sitting in
/// the middle. Returns the rewritten length, or null if it did not fit.
fn withoutCompression(head: []const u8, out: []u8) ?usize {
    var len: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const replacement = blk: {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse break :blk line;
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (!std.ascii.eqlIgnoreCase(name, "accept-encoding")) break :blk line;
            break :blk "accept-encoding: identity";
        };
        if (len + replacement.len + 2 > out.len) return null;
        @memcpy(out[len..][0..replacement.len], replacement);
        len += replacement.len;
        @memcpy(out[len..][0..2], "\r\n");
        len += 2;
    }
    // splitSequence yields a trailing empty field for the final CRLF, so the
    // blank line that ends the head is already there.
    return len - 2;
}

/// Reads one message from `from`, forwards it to `to`, and reports what it was.
/// `scratch` holds the head; `capture` receives up to its own length of body.
/// Returns null when the peer is done talking.
pub fn relay(
    session: *tls.Session,
    from: tls.Session.Side,
    to: tls.Session.Side,
    scratch: []u8,
    capture: []u8,
    is_response: bool,
) ?Summary {
    // ---- head: read until the blank line, one byte at a time. Slow, but it
    // guarantees not consuming a single byte of the body, which matters when
    // the body is framed by a header we have not parsed yet.
    var head_len: usize = 0;
    while (head_len < scratch.len) {
        const n = session.read(from, scratch[head_len .. head_len + 1]) orelse return null;
        if (n == 0) return null;
        head_len += 1;
        if (head_len >= 4 and std.mem.eql(u8, scratch[head_len - 4 .. head_len], "\r\n\r\n")) break;
    }
    if (head_len == 0) return null;

    const head = scratch[0..head_len];

    if (is_response) {
        if (!session.writeAll(to, head)) return null;
    } else {
        // Forward a request with compression turned off; the capture keeps the
        // original head so the record shows what the client actually asked for.
        var rewritten: [16 * 1024]u8 = undefined;
        if (withoutCompression(head, &rewritten)) |n| {
            if (!session.writeAll(to, rewritten[0..n])) return null;
        } else {
            if (!session.writeAll(to, head)) return null;
        }
    }

    const start_line = blk: {
        const end = std.mem.indexOf(u8, head, "\r\n") orelse head_len;
        break :blk head[0..end];
    };

    // A 204/304 response has no body regardless of headers.
    const bodyless = is_response and (std.mem.indexOf(u8, start_line, " 204 ") != null or
        std.mem.indexOf(u8, start_line, " 304 ") != null);

    const framing, const length = framingOf(head, bodyless);

    var body_bytes: usize = 0;
    var kept: usize = 0;
    var truncated = false;
    var buf: [16 * 1024]u8 = undefined;

    switch (framing) {
        .none => {},
        .length => {
            var left = length;
            while (left > 0) {
                const want = @min(left, buf.len);
                const n = session.read(from, buf[0..want]) orelse break;
                if (!session.writeAll(to, buf[0..n])) break;
                body_bytes += n;
                keep(capture, &kept, &truncated, buf[0..n]);
                left -= n;
            }
        },
        // Chunked and close-delimited bodies are forwarded opaquely: the framing
        // bytes travel with the payload, which is correct on the wire and good
        // enough to read in the capture.
        .chunked, .until_close => {
            while (true) {
                const n = session.read(from, &buf) orelse break;
                if (!session.writeAll(to, buf[0..n])) break;
                body_bytes += n;
                keep(capture, &kept, &truncated, buf[0..n]);
                if (framing == .chunked and std.mem.endsWith(u8, buf[0..n], "0\r\n\r\n")) break;
            }
        },
    }

    return .{
        .head = head,
        .start_line = start_line,
        .body_bytes = body_bytes,
        .body = capture[0..kept],
        .truncated = truncated,
    };
}

fn keep(capture: []u8, kept: *usize, truncated: *bool, bytes: []const u8) void {
    if (kept.* >= capture.len) {
        truncated.* = true;
        return;
    }
    const room = capture.len - kept.*;
    const take = @min(room, bytes.len);
    @memcpy(capture[kept.* .. kept.* + take], bytes[0..take]);
    kept.* += take;
    if (take < bytes.len) truncated.* = true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "credential headers are recognised regardless of case" {
    try testing.expect(isSecretHeader("Authorization"));
    try testing.expect(isSecretHeader("x-api-key"));
    try testing.expect(isSecretHeader("X-API-Key"));
    try testing.expect(!isSecretHeader("content-type"));
    try testing.expect(!isSecretHeader("x-api-version"));
}

test "redaction removes credential values and keeps the rest" {
    const head =
        "POST /v1/messages HTTP/1.1\r\n" ++
        "host: api.anthropic.com\r\n" ++
        "x-api-key: sk-ant-super-secret\r\n" ++
        "Authorization: Bearer nope\r\n" ++
        "content-type: application/json\r\n\r\n";

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try redactedHead(head, &w);
    const out = w.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "sk-ant-super-secret") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Bearer nope") == null);
    try testing.expect(std.mem.indexOf(u8, out, "x-api-key: <redacted>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Authorization: <redacted>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, out, "POST /v1/messages HTTP/1.1") != null);
}

test "compression is downgraded to identity" {
    const head =
        "POST /v1/messages HTTP/1.1\r\n" ++
        "host: api.anthropic.com\r\n" ++
        "Accept-Encoding: br, gzip, deflate\r\n" ++
        "content-type: application/json\r\n\r\n";

    var out: [512]u8 = undefined;
    const n = withoutCompression(head, &out).?;
    const rewritten = out[0..n];

    try testing.expect(std.mem.indexOf(u8, rewritten, "gzip") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "accept-encoding: identity") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "host: api.anthropic.com") != null);
    try testing.expect(std.mem.endsWith(u8, rewritten, "\r\n\r\n"));
}

test "framing is read from the headers" {
    const with_length = "HTTP/1.1 200 OK\r\ncontent-length: 42\r\n\r\n";
    const framing, const len = framingOf(with_length, false);
    try testing.expectEqual(Framing.length, framing);
    try testing.expectEqual(@as(usize, 42), len);

    const streamed = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n";
    try testing.expectEqual(Framing.chunked, framingOf(streamed, false)[0]);

    const nothing = "HTTP/1.1 204 No Content\r\n\r\n";
    try testing.expectEqual(Framing.none, framingOf(nothing, true)[0]);
}
