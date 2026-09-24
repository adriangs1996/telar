//! HTTP header rules the relays share: bounds, head kinds, typed effects,
//! name and value validation, the names that are always sensitive, and when
//! a response body is observable SSE.

const std = @import("std");
const Rewrite = @import("Rewrite.zig");
const rewrites = @import("rewrites.zig");

/// Recognizes the SSE media type while allowing parameters and ASCII case.
///
/// ```zig
/// const streaming = isEventStreamContentType("text/event-stream; charset=utf-8");
/// ```
pub fn isEventStreamContentType(value: []const u8) bool {
    const parameters = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, value[0..parameters], " \t"),
        "text/event-stream",
    );
}

/// Returns whether a present Content-Encoding value leaves bytes unchanged.
///
/// ```zig
/// const unchanged = isIdentityContentEncoding("identity");
/// ```
pub fn isIdentityContentEncoding(value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, value, ',');
    var found = false;

    while (tokens.next()) |token| {
        const coding = std.mem.trim(u8, token, " \t");

        if (coding.len == 0 or !std.ascii.eqlIgnoreCase(coding, "identity")) {
            return false;
        }

        found = true;
    }

    return found;
}

test "observable SSE headers require one event-stream type and identity bytes" {
    var headers: Headers = .{};
    try headers.append(.{ .name = "content-type", .value = "Text/Event-Stream; charset=utf-8" });
    try std.testing.expect(hasObservableSseBody(&headers));

    try headers.append(.{ .name = "content-encoding", .value = "identity" });
    try std.testing.expect(hasObservableSseBody(&headers));

    var encoded: Headers = .{};
    try encoded.append(.{ .name = "content-type", .value = "text/event-stream" });
    try encoded.append(.{ .name = "content-encoding", .value = "gzip" });
    try std.testing.expect(!hasObservableSseBody(&encoded));

    var duplicate: Headers = .{};
    try duplicate.append(.{ .name = "content-type", .value = "text/event-stream" });
    try duplicate.append(.{ .name = "content-type", .value = "text/event-stream" });
    try std.testing.expect(!hasObservableSseBody(&duplicate));

    var missing: Headers = .{};
    try missing.append(.{ .name = "content-encoding", .value = "identity" });
    try std.testing.expect(!hasObservableSseBody(&missing));
}

pub const max_header_fields = 256;

pub const max_header_bytes = 128 * 1024;

/// Effects one rewrite may apply to a head.
pub const max_effects = 32;

pub const HeaderKind = enum { request, response, trailers, push_promise };

pub const Direction = enum { request, response };

pub const HeaderView = @import("HeaderView.zig");

pub const Effect = union(enum) {
    remove: struct { name: []const u8 },
    set: struct {
        name: []const u8,
        value: []const u8,
        sensitive: bool,
    },
};

pub const HeaderField = @import("HeaderField.zig");

pub const Headers = @import("Headers.zig");

/// Returns whether decoded headers describe directly observable SSE bytes.
///
/// Missing Content-Encoding means identity. Duplicate Content-Type fields and
/// any content coding make the body ineligible.
///
/// ```zig
/// const observable = hasObservableSseBody(&headers);
/// ```
pub fn hasObservableSseBody(headers: *const Headers) bool {
    var content_type_seen = false;
    var event_stream = false;

    for (headers.fields[0..headers.len]) |field| {
        const name = headers.name(field);
        const value = headers.value(field);

        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            if (content_type_seen) {
                return false;
            }

            content_type_seen = true;
            event_stream = isEventStreamContentType(value);
        }

        if (std.ascii.eqlIgnoreCase(name, "content-encoding") and !isIdentityContentEncoding(value)) {
            return false;
        }
    }

    return content_type_seen and event_stream;
}

pub fn effectName(effect: Effect) []const u8 {
    return switch (effect) {
        .remove => |remove_effect| remove_effect.name,
        .set => |set_effect| set_effect.name,
    };
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) {
        return error.InvalidHeaderName;
    }
    for (name, 0..) |byte, index| {
        if (byte == ':' and index == 0) {
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '!' and byte != '#' and byte != '$' and byte != '%' and
            byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
            byte != '-' and byte != '.' and byte != '^' and byte != '_' and
            byte != '`' and byte != '|' and byte != '~')
        {
            return error.InvalidHeaderName;
        }
    }
}

pub fn validateValue(value: []const u8) !void {
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f)
        return error.InvalidHeaderValue;
}

pub fn isSensitiveName(name: []const u8) bool {
    inline for (.{
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
    }) |sensitive| if (std.ascii.eqlIgnoreCase(name, sensitive)) return true;
    return false;
}

test "header effect batches are atomic and preserve pseudo-header order" {
    var headers: Headers = .{};
    try headers.append(.{ .name = ":method", .value = "POST" });
    try headers.append(.{ .name = ":path", .value = "/v1/messages" });
    try headers.append(.{ .name = "authorization", .value = "secret", .sensitive = true });

    try headers.apply(&.{
        .{ .set = .{ .name = ":path", .value = "/v1/responses", .sensitive = false } },
        .{ .remove = .{ .name = "authorization" } },
        .{ .set = .{ .name = "x-telar", .value = "enabled", .sensitive = false } },
        .{ .set = .{ .name = "x-order", .value = "first", .sensitive = false } },
        .{ .remove = .{ .name = "x-order" } },
    });

    try std.testing.expectEqualStrings("POST", headers.find(":method").?);
    try std.testing.expectEqualStrings("/v1/responses", headers.find(":path").?);
    try std.testing.expect(headers.find("authorization") == null);
    try std.testing.expectEqualStrings("enabled", headers.find("x-telar").?);
    try std.testing.expect(headers.find("x-order") == null);
}

test "invalid complete effect batch preserves the original headers" {
    const invalid = [_]Rewrite{.{
        .effects = &.{.{ .set = .{ .name = ":new", .value = "invalid", .sensitive = false } }},
    }};
    var headers: Headers = .{};
    try headers.append(.{ .name = ":method", .value = "GET" });
    try std.testing.expect(!rewrites.apply(&invalid, .{ .direction = .request, .kind = .request }, &headers));
    try std.testing.expectEqual(@as(u16, 1), headers.len);
    try std.testing.expectEqualStrings("GET", headers.find(":method").?);
}

test "known secret headers remain sensitive regardless of transformer flags" {
    var headers: Headers = .{};
    try headers.append(.{ .name = "Authorization", .value = "Bearer secret" });
    try std.testing.expect(headers.fields[0].sensitive);

    try headers.apply(&.{.{ .set = .{ .name = "authorization", .value = "Bearer replacement", .sensitive = false } }});
    try std.testing.expect(headers.fields[0].sensitive);
}
