//! Bounded HTTP/1.1 framing for the intercepted TLS stream.
//!
//! The default path forwards heads and bodies byte for byte. An explicitly
//! installed transformer may rewrite a validated head; bodies always remain
//! streaming and unchanged.

const std = @import("std");
const middleware = @import("middleware.zig");
const tls = @import("tls.zig");

pub const max_head_bytes = 32 * 1024;
pub const max_chunk_line_bytes = 128;

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

pub fn relay(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    is_response: bool,
    response_to_head: bool,
    context: anytype,
    comptime activity: fn (@TypeOf(context), usize) void,
) ?Message {
    const head = relayHead(session, from, to, is_response, response_to_head) orelse return null;
    if (!relayBody(session, from, to, head.framing, context, activity)) return null;
    return head.message;
}

/// Relays exactly one HTTP head without consuming body bytes. Keeping this
/// boundary public lets the connection owner run the request body and response
/// concurrently, which is required for `Expect: 100-continue` and final
/// responses sent before an upload completes.
pub fn relayHead(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    is_response: bool,
    response_to_head: bool,
) ?Head {
    var head: [max_head_bytes]u8 = undefined;
    const head_len = readHead(session, from, &head) orelse return null;
    if (!session.writeAll(to, head[0..head_len])) return null;

    return analyzeHead(head[0..head_len], is_response, response_to_head);
}

/// Parses, transforms, validates, and relays one head. An invalid or oversized
/// effect batch preserves the original bytes. Body framing and connection
/// semantics cannot change until a body-transform contract exists.
pub fn relayHeadTransformed(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    is_response: bool,
    response_to_head: bool,
    pipeline: *const middleware.TransformPipeline,
    io: std.Io,
    transform_context: middleware.TransformContext,
) ?Head {
    if (pipeline.len == 0)
        return relayHead(session, from, to, is_response, response_to_head);

    var original: [max_head_bytes]u8 = undefined;
    const original_len = readHead(session, from, &original) orelse return null;
    const original_head = analyzeHead(
        original[0..original_len],
        is_response,
        response_to_head,
    ) orelse return null;
    var headers: middleware.Headers = .{};
    const start_line = parseHeaders(
        original[0..original_len],
        is_response,
        &headers,
    ) orelse {
        if (!session.writeAll(to, original[0..original_len])) return null;
        return original_head;
    };
    const changed = pipeline.apply(io, transform_context, &headers);
    if (!changed) {
        if (!session.writeAll(to, original[0..original_len])) return null;
        return original_head;
    }

    var encoded: [max_head_bytes]u8 = undefined;
    const encoded_len = encodeHead(&encoded, start_line, is_response, &headers) orelse {
        if (!session.writeAll(to, original[0..original_len])) return null;
        return original_head;
    };
    var transformed = analyzeHead(
        encoded[0..encoded_len],
        is_response,
        response_to_head,
    ) orelse {
        if (!session.writeAll(to, original[0..original_len])) return null;
        return original_head;
    };
    if (!compatible(original_head, transformed)) {
        if (!session.writeAll(to, original[0..original_len])) return null;
        return original_head;
    }
    transformed.inference_request = original_head.inference_request;
    if (!session.writeAll(to, encoded[0..encoded_len])) return null;
    return transformed;
}

fn analyzeHead(
    head: []const u8,
    is_response: bool,
    response_to_head: bool,
) ?Head {
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    const start_line = head[0..first_line_end];
    const status_code = if (is_response) parseStatus(start_line) else 0;
    const bodyless = is_response and (response_to_head or
        (status_code >= 100 and status_code < 200) or
        status_code == 204 or status_code == 205 or status_code == 304);
    const framing = framingOf(head, is_response, bodyless) orelse return null;
    return .{
        .message = .{
            .status_code = status_code,
            .head_request = !is_response and isHeadRequest(start_line),
            .informational = is_response and status_code >= 100 and status_code < 200 and
                status_code != 101,
            .upgrade = is_response and status_code == 101,
            .closes = switch (framing) {
                .until_close => true,
                else => connectionCloses(head),
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

fn compatible(original: Head, transformed: Head) bool {
    return std.meta.eql(original.framing, transformed.framing) and
        original.message.informational == transformed.message.informational and
        original.message.upgrade == transformed.message.upgrade and
        original.message.closes == transformed.message.closes;
}

fn parseHeaders(
    head: []const u8,
    is_response: bool,
    headers: *middleware.Headers,
) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse return null;
    const start_line = head[0..first_line_end];
    if (is_response) {
        var parts = std.mem.splitScalar(u8, start_line, ' ');
        _ = parts.next() orelse return null;
        const status = parts.next() orelse return null;
        headers.append(":status", status, false) catch return null;
    } else {
        const method_end = std.mem.indexOfScalar(u8, start_line, ' ') orelse return null;
        const version_start = std.mem.lastIndexOfScalar(u8, start_line, ' ') orelse return null;
        if (method_end == version_start) return null;
        headers.append(":method", start_line[0..method_end], false) catch return null;
        headers.append(":path", start_line[method_end + 1 .. version_start], false) catch return null;
    }
    var lines = std.mem.splitSequence(u8, head[first_line_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        headers.append(name, value, middleware.isSensitiveName(name)) catch return null;
    }
    return start_line;
}

fn encodeHead(
    output: []u8,
    start_line: []const u8,
    is_response: bool,
    headers: *const middleware.Headers,
) ?usize {
    var len: usize = 0;
    if (is_response) {
        const version_end = std.mem.indexOfScalar(u8, start_line, ' ') orelse return null;
        const status_end = std.mem.indexOfScalarPos(u8, start_line, version_end + 1, ' ') orelse
            start_line.len;
        const status = headers.find(":status") orelse return null;
        const status_code = std.fmt.parseInt(u16, status, 10) catch return null;
        if (status.len != 3 or status_code < 100 or status_code > 599) return null;
        appendEncoded(output, &len, start_line[0..version_end]) orelse return null;
        appendEncoded(output, &len, " ") orelse return null;
        appendEncoded(output, &len, status) orelse return null;
        appendEncoded(output, &len, start_line[status_end..]) orelse return null;
    } else {
        const version_start = std.mem.lastIndexOfScalar(u8, start_line, ' ') orelse return null;
        const method = headers.find(":method") orelse return null;
        const target = headers.find(":path") orelse return null;
        if (!validMethod(method) or target.len == 0 or
            std.mem.indexOfAny(u8, target, " \t") != null) return null;
        if (std.mem.eql(u8, start_line[version_start + 1 ..], "HTTP/1.1") and
            !hasOneNonemptyHeader(headers, "host")) return null;
        appendEncoded(output, &len, method) orelse return null;
        appendEncoded(output, &len, " ") orelse return null;
        appendEncoded(output, &len, target) orelse return null;
        appendEncoded(output, &len, start_line[version_start..]) orelse return null;
    }
    appendEncoded(output, &len, "\r\n") orelse return null;
    for (headers.fields[0..headers.len]) |field| {
        if (headers.name(field)[0] == ':') continue;
        appendEncoded(output, &len, headers.name(field)) orelse return null;
        appendEncoded(output, &len, ": ") orelse return null;
        appendEncoded(output, &len, headers.value(field)) orelse return null;
        appendEncoded(output, &len, "\r\n") orelse return null;
    }
    appendEncoded(output, &len, "\r\n") orelse return null;
    return len;
}

fn hasOneNonemptyHeader(headers: *const middleware.Headers, wanted: []const u8) bool {
    var count: usize = 0;
    for (headers.fields[0..headers.len]) |field| {
        if (!std.ascii.eqlIgnoreCase(headers.name(field), wanted)) continue;
        if (headers.value(field).len == 0) return false;
        count += 1;
    }
    return count == 1;
}

fn validMethod(method: []const u8) bool {
    if (method.len == 0) return false;
    for (method) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '!' and byte != '#' and byte != '$' and byte != '%' and
        byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
        byte != '-' and byte != '.' and byte != '^' and byte != '_' and
        byte != '`' and byte != '|' and byte != '~') return false;
    return true;
}

fn appendEncoded(output: []u8, len: *usize, bytes: []const u8) ?void {
    if (bytes.len > output.len - len.*) return null;
    @memcpy(output[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
}

pub fn relayBody(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    framing: Framing,
    context: anytype,
    comptime activity: fn (@TypeOf(context), usize) void,
) bool {
    switch (framing) {
        .none => {},
        .length => |len| if (!relayExact(session, from, to, len, context, activity)) return false,
        .chunked => if (!relayChunked(session, from, to, context, activity)) return false,
        .until_close => {
            var buffer: [16 * 1024]u8 = undefined;
            while (session.read(from, &buffer)) |len| {
                if (!session.writeAll(to, buffer[0..len])) return false;
                activity(context, len);
            }
        },
    }
    return true;
}

fn readHead(session: anytype, side: tls.Session.Side, buffer: []u8) ?usize {
    var len: usize = 0;
    while (len < buffer.len) {
        const read = session.read(side, buffer[len..][0..1]) orelse return null;
        if (read != 1) return null;
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buffer[len - 4 .. len], "\r\n\r\n")) return len;
    }
    return null;
}

fn relayExact(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    count: usize,
    context: anytype,
    comptime activity: fn (@TypeOf(context), usize) void,
) bool {
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

fn relayChunked(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    context: anytype,
    comptime activity: fn (@TypeOf(context), usize) void,
) bool {
    var line: [max_chunk_line_bytes]u8 = undefined;
    while (true) {
        const line_len = relayLine(session, from, to, &line) orelse return false;
        const trimmed = std.mem.trim(u8, line[0..line_len], " \t\r\n");
        const extension = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const chunk_len = std.fmt.parseInt(usize, trimmed[0..extension], 16) catch return false;
        if (chunk_len == 0) {
            while (true) {
                const trailer_len = relayLine(session, from, to, &line) orelse return false;
                if (trailer_len == 2 and std.mem.eql(u8, line[0..2], "\r\n")) return true;
            }
        }
        if (!relayExact(session, from, to, chunk_len + 2, context, activity)) return false;
    }
}

fn relayLine(
    session: anytype,
    from: tls.Session.Side,
    to: tls.Session.Side,
    buffer: []u8,
) ?usize {
    var len: usize = 0;
    while (len < buffer.len) {
        const read = session.read(from, buffer[len..][0..1]) orelse return null;
        if (read != 1 or !session.writeAll(to, buffer[len..][0..1])) return null;
        len += 1;
        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) return len;
    }
    return null;
}

fn framingOf(head: []const u8, is_response: bool, bodyless: bool) ?Framing {
    if (bodyless) return .none;
    var transfer_encoding: ?[]const u8 = null;
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
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

fn connectionCloses(head: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
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

test "HTTP framing recognizes chunked and fixed bodies" {
    try std.testing.expectEqual(Framing.chunked, framingOf(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        true,
        false,
    ).?);
    try std.testing.expectEqualDeep(Framing{ .length = 42 }, framingOf(
        "POST / HTTP/1.1\r\nContent-Length: 42\r\n\r\n",
        false,
        false,
    ).?);
}

test "status and connection tokens are parsed case insensitively" {
    try std.testing.expectEqual(@as(u16, 429), parseStatus("HTTP/1.1 429 Too Many Requests"));
    try std.testing.expect(connectionCloses("HTTP/1.1 200 OK\r\nConnection: keep-alive, Close\r\n\r\n"));
}

test "HTTP framing rejects ambiguous lengths and recognizes HEAD" {
    try std.testing.expect(framingOf(
        "POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\n",
        false,
        false,
    ) == null);
    try std.testing.expect(framingOf(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n",
        false,
        false,
    ) == null);
    try std.testing.expectEqual(Framing.none, framingOf(
        "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n",
        true,
        true,
    ).?);
    try std.testing.expect(isHeadRequest("HEAD /v1/messages HTTP/1.1"));
}

test "HTTP1 inference classification ignores auxiliary provider routes" {
    try std.testing.expect(analyzeHead(
        "POST /v1/messages?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
    try std.testing.expect(!analyzeHead(
        "POST /v1/messages/count_tokens?beta=true HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
    try std.testing.expect(!analyzeHead(
        "POST /api/event_logging/v2/batch HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        false,
        false,
    ).?.inference_request);
}

test "body framing exposes whether a concurrent relay is required" {
    try std.testing.expect(!Framing.hasBody(.none));
    try std.testing.expect(!(Framing{ .length = 0 }).hasBody());
    try std.testing.expect((Framing{ .length = 1 }).hasBody());
    try std.testing.expect(Framing.hasBody(.chunked));
}

const FakeSession = struct {
    child_input: []const u8 = "",
    origin_input: []const u8 = "",
    child_offset: usize = 0,
    origin_offset: usize = 0,
    child_output: [1024]u8 = undefined,
    child_output_len: usize = 0,
    origin_output: [1024]u8 = undefined,
    origin_output_len: usize = 0,

    fn read(fake: *FakeSession, side: tls.Session.Side, buffer: []u8) ?usize {
        const input, const offset = switch (side) {
            .child => .{ fake.child_input, &fake.child_offset },
            .origin => .{ fake.origin_input, &fake.origin_offset },
        };
        if (offset.* == input.len) return null;
        const take = @min(buffer.len, input.len - offset.*);
        @memcpy(buffer[0..take], input[offset.*..][0..take]);
        offset.* += take;
        return take;
    }

    fn writeAll(fake: *FakeSession, side: tls.Session.Side, bytes: []const u8) bool {
        const output, const len = switch (side) {
            .child => .{ &fake.child_output, &fake.child_output_len },
            .origin => .{ &fake.origin_output, &fake.origin_output_len },
        };
        if (bytes.len > output.len - len.*) return false;
        @memcpy(output[len.*..][0..bytes.len], bytes);
        len.* += bytes.len;
        return true;
    }
};

fn ignoreTestActivity(_: void, _: usize) void {}

test "Expect request head is forwarded before its body is consumed" {
    const request = "POST /upload HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "Expect: 100-continue\r\n" ++
        "Content-Length: 4\r\n\r\n" ++
        "data";
    const head_len = std.mem.indexOf(u8, request, "\r\n\r\n").? + 4;
    var fake: FakeSession = .{ .child_input = request };
    const head = relayHead(&fake, .child, .origin, false, false).?;
    try std.testing.expectEqual(head_len, fake.child_offset);
    try std.testing.expectEqualStrings(request[0..head_len], fake.origin_output[0..fake.origin_output_len]);
    try std.testing.expect(head.framing.hasBody());

    try std.testing.expect(relayBody(
        &fake,
        .child,
        .origin,
        head.framing,
        {},
        ignoreTestActivity,
    ));
    try std.testing.expectEqualStrings(request, fake.origin_output[0..fake.origin_output_len]);
}

test "HTTP1 transform rewrites safe headers and preserves body framing" {
    const AddHeader = struct {
        fn transform(
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
    try pipeline.add(.{ .context = &ignored, .transform = AddHeader.transform });
    const request = "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata";
    var fake: FakeSession = .{ .child_input = request };
    const head = relayHeadTransformed(
        &fake,
        .child,
        .origin,
        false,
        false,
        &pipeline,
        std.testing.io,
        undefined,
    ).?;
    try std.testing.expectEqualDeep(Framing{ .length = 4 }, head.framing);
    try std.testing.expect(std.mem.indexOf(
        u8,
        fake.origin_output[0..fake.origin_output_len],
        "x-telar: enabled\r\n",
    ) != null);
}

test "HTTP1 no-op transformer preserves the exact head bytes" {
    const NoOp = struct {
        fn transform(
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
    try pipeline.add(.{ .context = &ignored, .transform = NoOp.transform });
    const request = "GET / HTTP/1.1\r\nhOsT:\texample.test\r\nX-Duplicate: one\r\nX-Duplicate: two\r\n\r\n";
    var fake: FakeSession = .{ .child_input = request };
    _ = relayHeadTransformed(
        &fake,
        .child,
        .origin,
        false,
        false,
        &pipeline,
        std.testing.io,
        undefined,
    ).?;
    try std.testing.expectEqualStrings(request, fake.origin_output[0..fake.origin_output_len]);
}

test "HTTP1 transform cannot change body framing" {
    const ChangeLength = struct {
        fn transform(
            _: *anyopaque,
            _: std.Io,
            _: middleware.HeaderSnapshot,
            effects: *middleware.EffectBatch,
        ) middleware.TransformStatus {
            effects.set("content-length", "5", false) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = ChangeLength.transform });
    const request = "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\ndata";
    const head_len = std.mem.indexOf(u8, request, "\r\n\r\n").? + 4;
    var fake: FakeSession = .{ .child_input = request };
    _ = relayHeadTransformed(
        &fake,
        .child,
        .origin,
        false,
        false,
        &pipeline,
        std.testing.io,
        undefined,
    ).?;
    try std.testing.expectEqualStrings(
        request[0..head_len],
        fake.origin_output[0..fake.origin_output_len],
    );
}

test "HTTP1 request pseudo-headers transform method and target" {
    const RewriteTarget = struct {
        fn transform(
            _: *anyopaque,
            _: std.Io,
            _: middleware.HeaderSnapshot,
            effects: *middleware.EffectBatch,
        ) middleware.TransformStatus {
            effects.set(":method", "PUT", false) catch return .preserve;
            effects.set(":path", "/v1/responses", false) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = RewriteTarget.transform });
    const request = "POST /v1/messages HTTP/1.1\r\nHost: example.test\r\nContent-Length: 0\r\n\r\n";
    var fake: FakeSession = .{ .child_input = request };
    const head = relayHeadTransformed(
        &fake,
        .child,
        .origin,
        false,
        false,
        &pipeline,
        std.testing.io,
        undefined,
    ).?;
    try std.testing.expect(head.inference_request);
    try std.testing.expect(std.mem.startsWith(
        u8,
        fake.origin_output[0..fake.origin_output_len],
        "PUT /v1/responses HTTP/1.1\r\n",
    ));
}

test "informational response is delimited before the final response" {
    const responses = "HTTP/1.1 100 Continue\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    var fake: FakeSession = .{ .origin_input = responses };
    const informational = relay(
        &fake,
        .origin,
        .child,
        true,
        false,
        {},
        ignoreTestActivity,
    ).?;
    try std.testing.expect(informational.informational);
    const final = relay(
        &fake,
        .origin,
        .child,
        true,
        false,
        {},
        ignoreTestActivity,
    ).?;
    try std.testing.expectEqual(@as(u16, 200), final.status_code);
    try std.testing.expectEqualStrings(responses, fake.child_output[0..fake.child_output_len]);
}
