//! Header transformation for HTTP/1.1 messages.
//!
//! This module never reads or writes a session. It converts a complete head to
//! middleware headers, applies the bounded pipeline, re-encodes the result, and
//! accepts it only when HTTP framing and connection semantics stay unchanged.

const std = @import("std");
const head = @import("head.zig");
const middleware = @import("../middleware.zig");

pub const Decision = union(enum) {
    preserve,
    replace: struct {
        head: head.Head,
        len: usize,
    },
};

/// Chooses whether the caller should preserve or replace an HTTP head.
///
/// Every parsing, middleware, encoding, size, or compatibility failure returns
/// `.preserve`. On `.replace`, the encoded bytes occupy `output[0..len]`.
pub fn decide(
    original: []const u8,
    original_head: head.Head,
    is_response: bool,
    response_to_head: bool,
    pipeline: *const middleware.TransformPipeline,
    io: std.Io,
    context: middleware.TransformContext,
    output: []u8,
) Decision {
    var headers: middleware.Headers = .{};
    const start_line = parseHeaders(original, is_response, &headers) orelse return .preserve;
    if (!pipeline.apply(io, context, &headers)) return .preserve;

    const len = encodeHead(output, start_line, is_response, &headers) orelse return .preserve;
    var transformed = head.analyze(output[0..len], .{
        .is_response = is_response,
        .response_to_head = response_to_head,
    }) orelse return .preserve;
    if (!compatible(original_head, transformed)) return .preserve;

    transformed.classification = original_head.classification;
    return .{ .replace = .{ .head = transformed, .len = len } };
}

fn compatible(original: head.Head, transformed: head.Head) bool {
    return std.meta.eql(original.framing, transformed.framing) and
        original.message.informational == transformed.message.informational and
        original.message.upgrade == transformed.message.upgrade and
        original.message.closes == transformed.message.closes;
}

fn parseHeaders(
    bytes: []const u8,
    is_response: bool,
    headers: *middleware.Headers,
) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
    const start_line = bytes[0..first_line_end];
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

    var lines = std.mem.splitSequence(u8, bytes[first_line_end + 2 ..], "\r\n");
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
        append(output, &len, start_line[0..version_end]) orelse return null;
        append(output, &len, " ") orelse return null;
        append(output, &len, status) orelse return null;
        append(output, &len, start_line[status_end..]) orelse return null;
    } else {
        const version_start = std.mem.lastIndexOfScalar(u8, start_line, ' ') orelse return null;
        const method = headers.find(":method") orelse return null;
        const target = headers.find(":path") orelse return null;
        if (!validMethod(method) or target.len == 0 or
            std.mem.indexOfAny(u8, target, " \t") != null) return null;
        if (std.mem.eql(u8, start_line[version_start + 1 ..], "HTTP/1.1") and
            !hasOneNonemptyHeader(headers, "host")) return null;
        append(output, &len, method) orelse return null;
        append(output, &len, " ") orelse return null;
        append(output, &len, target) orelse return null;
        append(output, &len, start_line[version_start..]) orelse return null;
    }

    append(output, &len, "\r\n") orelse return null;
    for (headers.fields[0..headers.len]) |field| {
        if (headers.name(field)[0] == ':') continue;
        append(output, &len, headers.name(field)) orelse return null;
        append(output, &len, ": ") orelse return null;
        append(output, &len, headers.value(field)) orelse return null;
        append(output, &len, "\r\n") orelse return null;
    }
    append(output, &len, "\r\n") orelse return null;
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

fn append(output: []u8, len: *usize, bytes: []const u8) ?void {
    if (bytes.len > output.len - len.*) return null;
    @memcpy(output[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
}

fn testDecision(
    original: []const u8,
    is_response: bool,
    pipeline: *const middleware.TransformPipeline,
    output: []u8,
) Decision {
    return decide(
        original,
        head.analyze(original, .{
            .is_response = is_response,
            .response_to_head = false,
            .provider = if (is_response) .unknown else .claude,
        }).?,
        is_response,
        false,
        pipeline,
        std.testing.io,
        undefined,
        output,
    );
}

test "a safe header transformation produces a replacement" {
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
    const original = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var output: [head.max_bytes]u8 = undefined;

    const replacement = switch (testDecision(original, false, &pipeline, &output)) {
        .preserve => return error.ExpectedReplacement,
        .replace => |value| value,
    };

    try std.testing.expect(std.mem.indexOf(
        u8,
        output[0..replacement.len],
        "x-telar: enabled\r\n",
    ) != null);
}

test "a transformer without effects preserves the original" {
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
    const original = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var output: [head.max_bytes]u8 = undefined;

    try std.testing.expectEqual(Decision.preserve, testDecision(
        original,
        false,
        &pipeline,
        &output,
    ));
}

test "a transformation cannot change body framing" {
    const ChangeLength = struct {
        fn apply(
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
    try pipeline.add(.{ .context = &ignored, .transform = ChangeLength.apply });
    const original = "POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 4\r\n\r\n";
    var output: [head.max_bytes]u8 = undefined;

    try std.testing.expectEqual(Decision.preserve, testDecision(
        original,
        false,
        &pipeline,
        &output,
    ));
}

test "invalid transformed request lines preserve the original" {
    const InvalidMethod = struct {
        fn apply(
            _: *anyopaque,
            _: std.Io,
            _: middleware.HeaderSnapshot,
            effects: *middleware.EffectBatch,
        ) middleware.TransformStatus {
            effects.set(":method", "NOT VALID", false) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = InvalidMethod.apply });
    const original = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var output: [head.max_bytes]u8 = undefined;

    try std.testing.expectEqual(Decision.preserve, testDecision(
        original,
        false,
        &pipeline,
        &output,
    ));
}

test "an encoded head that exceeds the output bound is preserved" {
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
    const original = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var output: [8]u8 = undefined;

    try std.testing.expectEqual(Decision.preserve, testDecision(
        original,
        false,
        &pipeline,
        &output,
    ));
}

test "request classification remains tied to the original route" {
    const RewriteRoute = struct {
        fn apply(
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
    try pipeline.add(.{ .context = &ignored, .transform = RewriteRoute.apply });
    const original = "POST /v1/messages HTTP/1.1\r\nHost: example.test\r\nContent-Length: 0\r\n\r\n";
    var output: [head.max_bytes]u8 = undefined;

    const replacement = switch (testDecision(original, false, &pipeline, &output)) {
        .preserve => return error.ExpectedReplacement,
        .replace => |value| value,
    };
    try std.testing.expectEqual(@import("../provider/request.zig").RequestClass.inference, replacement.head.classification);
    try std.testing.expect(std.mem.startsWith(
        u8,
        output[0..replacement.len],
        "PUT /v1/responses HTTP/1.1\r\n",
    ));
}
