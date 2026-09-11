//! Bounded proxy observation and header-transformation contracts.
//!
//! Observers never affect traffic. Header transforms receive immutable views
//! and return a complete semantic effect batch. The caller validates and
//! applies the whole batch or preserves the original headers. A future Lua
//! worker can copy the same value snapshot across its bounded queue without
//! exposing a tunnel, TLS session, or Zig pointer to the VM.

const std = @import("std");
const core = @import("telar-core");
const dialect_mod = @import("provider/dialect.zig");
const identity = @import("identity.zig");

pub const schema = core.schema;

pub const Phase = enum {
    request_started,
    auxiliary_request_started,
    response_activity,
    provider_turn_completed,
    response_finished,
    request_failed,
};

pub const Protocol = enum { http11, h2, upgraded };
pub const ApiDialect = dialect_mod.ApiDialect;

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

pub const Event = @import("MiddlewareEvent.zig");

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

pub const Observer = @import("Observer.zig");

pub const max_observers = 8;

pub const Pipeline = @import("Pipeline.zig");

pub const max_header_fields = 256;
pub const max_header_bytes = 128 * 1024;
pub const max_transformers = 8;
pub const max_effects = 32;
pub const max_effect_bytes = 8 * 1024;

pub const HeaderKind = enum { request, response, trailers, push_promise };
pub const Direction = enum { request, response };

pub const TransformContext = @import("TransformContext.zig");

pub const HeaderView = @import("HeaderView.zig");

pub const HeaderSnapshot = @import("HeaderSnapshot.zig");

pub const Effect = union(enum) {
    remove: struct { name: []const u8 },
    set: struct {
        name: []const u8,
        value: []const u8,
        sensitive: bool,
    },
};

pub const EffectBatch = @import("EffectBatch.zig");

pub const TransformStatus = enum {
    apply,
    preserve,
};

pub const Transformation = @import("Transformation.zig");

pub const Transformer = @import("Transformer.zig");

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

pub const TransformPipeline = @import("TransformPipeline.zig");

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

    var effects: EffectBatch = .{};
    try effects.set(.{ .name = ":path", .value = "/v1/responses" });
    try effects.remove("authorization");
    try effects.set(.{ .name = "x-telar", .value = "enabled" });
    try effects.set(.{ .name = "x-order", .value = "first" });
    try effects.remove("x-order");
    try headers.apply(effects.effects[0..effects.len]);

    try std.testing.expectEqualStrings("POST", headers.find(":method").?);
    try std.testing.expectEqualStrings("/v1/responses", headers.find(":path").?);
    try std.testing.expect(headers.find("authorization") == null);
    try std.testing.expectEqualStrings("enabled", headers.find("x-telar").?);
    try std.testing.expect(headers.find("x-order") == null);
}

test "invalid complete effect batch preserves the original headers" {
    const TransformerImpl = struct {
        fn transform(_: *anyopaque, transformation: Transformation) TransformStatus {
            transformation.effects.set(.{ .name = ":new", .value = "invalid" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = TransformerImpl.transform });
    var headers: Headers = .{};
    try headers.append(.{ .name = ":method", .value = "GET" });
    try std.testing.expect(!pipeline.apply(.{ .io = std.testing.io, .context = undefined, .headers = &headers }));
    try std.testing.expectEqual(@as(u16, 1), headers.len);
    try std.testing.expectEqualStrings("GET", headers.find(":method").?);
}

test "known secret headers remain sensitive regardless of transformer flags" {
    var headers: Headers = .{};
    try headers.append(.{ .name = "Authorization", .value = "Bearer secret" });
    try std.testing.expect(headers.fields[0].sensitive);

    var effects: EffectBatch = .{};
    try effects.set(.{ .name = "authorization", .value = "Bearer replacement" });
    try headers.apply(effects.effects[0..effects.len]);
    try std.testing.expect(headers.fields[0].sensitive);
}
