//! Bounded proxy observation and header-transformation contracts.
//!
//! Observers never affect traffic. Header transforms receive immutable views
//! and return a complete semantic effect batch. The caller validates and
//! applies the whole batch or preserves the original headers. A future Lua
//! worker can copy the same value snapshot across its bounded queue without
//! exposing a tunnel, TLS session, or Zig pointer to the VM.

const std = @import("std");
const core = @import("telar-core");
const identity = @import("identity.zig");

const schema = core.schema;

pub const Phase = enum {
    request_started,
    response_activity,
    response_finished,
    request_failed,
};

pub const Protocol = enum { http11, h2, upgraded };

pub const Event = struct {
    credential: identity.Credential,
    provider: schema.AgentProvider,
    phase: Phase,
    protocol: Protocol,
    connection_id: u64,
    stream_id: u32 = 0,
    status_code: u16 = 0,
    observed_at_ms: i64,
};

pub const Observer = struct {
    context: *anyopaque,
    observe: *const fn (*anyopaque, std.Io, Event) void,
};

pub const max_observers = 8;

/// Immutable after the listener starts, so concurrent tunnels need no lock.
pub const Pipeline = struct {
    observers: [max_observers]Observer = undefined,
    len: u8 = 0,

    pub fn add(pipeline: *Pipeline, observer: Observer) !void {
        if (pipeline.len == pipeline.observers.len) return error.TooManyProxyObservers;
        pipeline.observers[pipeline.len] = observer;
        pipeline.len += 1;
    }

    pub fn publish(pipeline: *const Pipeline, io: std.Io, event: Event) void {
        for (pipeline.observers[0..pipeline.len]) |observer|
            observer.observe(observer.context, io, event);
    }
};

pub const max_header_fields = 256;
pub const max_header_bytes = 128 * 1024;
pub const max_transformers = 8;
pub const max_effects = 32;
pub const max_effect_bytes = 8 * 1024;

pub const HeaderKind = enum { request, response, trailers, push_promise };
pub const Direction = enum { request, response };

pub const TransformContext = struct {
    pane_id: schema.PaneId,
    pane_generation: u64,
    provider: schema.AgentProvider,
    protocol: Protocol,
    direction: Direction,
    kind: HeaderKind,
    connection_id: u64,
    stream_id: u32,
};

pub const HeaderView = struct {
    name: []const u8,
    value: []const u8,
    sensitive: bool = false,
};

pub const HeaderSnapshot = struct {
    context: TransformContext,
    fields: []const HeaderView,
};

pub const Effect = union(enum) {
    remove: struct { name: []const u8 },
    set: struct {
        name: []const u8,
        value: []const u8,
        sensitive: bool,
    },
};

/// Storage is owned by the callback invocation. Future worker adapters copy
/// the completed batch before returning it to the tunnel actor.
pub const EffectBatch = struct {
    effects: [max_effects]Effect = undefined,
    len: u8 = 0,
    bytes: [max_effect_bytes]u8 = undefined,
    bytes_len: usize = 0,

    pub fn remove(batch: *EffectBatch, name: []const u8) !void {
        const owned_name = try batch.copy(name);
        try batch.append(.{ .remove = .{ .name = owned_name } });
    }

    pub fn set(
        batch: *EffectBatch,
        name: []const u8,
        value: []const u8,
        sensitive: bool,
    ) !void {
        const owned_name = try batch.copy(name);
        const owned_value = try batch.copy(value);
        try batch.append(.{ .set = .{
            .name = owned_name,
            .value = owned_value,
            .sensitive = sensitive,
        } });
    }

    fn append(batch: *EffectBatch, effect: Effect) !void {
        if (batch.len == batch.effects.len) return error.TooManyHeaderEffects;
        batch.effects[batch.len] = effect;
        batch.len += 1;
    }

    fn copy(batch: *EffectBatch, value: []const u8) ![]const u8 {
        if (value.len > batch.bytes.len - batch.bytes_len)
            return error.HeaderEffectsTooLarge;
        const start = batch.bytes_len;
        @memcpy(batch.bytes[start..][0..value.len], value);
        batch.bytes_len += value.len;
        return batch.bytes[start..batch.bytes_len];
    }
};

pub const TransformStatus = enum {
    apply,
    preserve,
};

pub const Transformer = struct {
    context: *anyopaque,
    transform: *const fn (*anyopaque, std.Io, HeaderSnapshot, *EffectBatch) TransformStatus,
};

pub const HeaderField = struct {
    name_start: u32,
    name_len: u32,
    value_start: u32,
    value_len: u32,
    sensitive: bool,
};

/// Fixed owned header storage. Offsets remain valid when the value moves.
pub const Headers = struct {
    fields: [max_header_fields]HeaderField = undefined,
    len: u16 = 0,
    bytes: [max_header_bytes]u8 = undefined,
    bytes_len: usize = 0,

    pub fn append(
        headers: *Headers,
        header_name: []const u8,
        header_value: []const u8,
        sensitive: bool,
    ) !void {
        try validateName(header_name);
        try validateValue(header_value);
        if (headers.len == headers.fields.len) return error.TooManyHeaders;
        if (header_name.len + header_value.len > headers.bytes.len - headers.bytes_len)
            return error.HeadersTooLarge;
        const name_start = headers.bytes_len;
        @memcpy(headers.bytes[name_start..][0..header_name.len], header_name);
        headers.bytes_len += header_name.len;
        const value_start = headers.bytes_len;
        @memcpy(headers.bytes[value_start..][0..header_value.len], header_value);
        headers.bytes_len += header_value.len;
        headers.fields[headers.len] = .{
            .name_start = @intCast(name_start),
            .name_len = @intCast(header_name.len),
            .value_start = @intCast(value_start),
            .value_len = @intCast(header_value.len),
            .sensitive = sensitive or isSensitiveName(header_name),
        };
        headers.len += 1;
    }

    pub fn name(headers: *const Headers, field: HeaderField) []const u8 {
        return headers.bytes[field.name_start..][0..field.name_len];
    }

    pub fn value(headers: *const Headers, field: HeaderField) []const u8 {
        return headers.bytes[field.value_start..][0..field.value_len];
    }

    pub fn find(headers: *const Headers, wanted: []const u8) ?[]const u8 {
        for (headers.fields[0..headers.len]) |field|
            if (std.ascii.eqlIgnoreCase(headers.name(field), wanted))
                return headers.value(field);
        return null;
    }

    pub fn copyFrom(destination: *Headers, source: *const Headers) void {
        destination.len = source.len;
        destination.bytes_len = source.bytes_len;
        @memcpy(
            destination.fields[0..source.len],
            source.fields[0..source.len],
        );
        @memcpy(
            destination.bytes[0..source.bytes_len],
            source.bytes[0..source.bytes_len],
        );
    }

    pub fn views(
        headers: *const Headers,
        storage: *[max_header_fields]HeaderView,
    ) []const HeaderView {
        for (headers.fields[0..headers.len], 0..) |field, index| storage[index] = .{
            .name = headers.name(field),
            .value = headers.value(field),
            .sensitive = field.sensitive,
        };
        return storage[0..headers.len];
    }

    pub fn apply(headers: *Headers, effects: []const Effect) !void {
        if (effects.len == 0) return;
        var replacement: Headers = .{};
        var inserted: [max_effects]bool = @splat(false);

        for (headers.fields[0..headers.len]) |field| {
            const field_name = headers.name(field);
            var last_match: ?usize = null;
            for (effects, 0..) |effect, effect_index| {
                if (std.ascii.eqlIgnoreCase(field_name, effectName(effect))) {
                    last_match = effect_index;
                }
            }
            if (last_match) |effect_index| switch (effects[effect_index]) {
                .remove => {},
                .set => |set_effect| if (!inserted[effect_index]) {
                    try replacement.append(
                        set_effect.name,
                        set_effect.value,
                        set_effect.sensitive,
                    );
                    inserted[effect_index] = true;
                },
            } else try replacement.append(
                field_name,
                headers.value(field),
                field.sensitive,
            );
        }

        // New pseudo-headers must precede regular headers. Effects that replace
        // an existing pseudo-header were inserted in its original position.
        for (effects, 0..) |effect, effect_index| switch (effect) {
            .remove => {},
            .set => |set_effect| if (!inserted[effect_index]) {
                var superseded = false;
                for (effects[effect_index + 1 ..]) |later|
                    if (std.ascii.eqlIgnoreCase(set_effect.name, effectName(later))) {
                        superseded = true;
                        break;
                    };
                if (superseded) continue;
                if (set_effect.name.len != 0 and set_effect.name[0] == ':')
                    return error.CannotInsertPseudoHeader;
                try replacement.append(
                    set_effect.name,
                    set_effect.value,
                    set_effect.sensitive,
                );
            },
        };
        headers.copyFrom(&replacement);
    }
};

fn effectName(effect: Effect) []const u8 {
    return switch (effect) {
        .remove => |remove_effect| remove_effect.name,
        .set => |set_effect| set_effect.name,
    };
}

/// Immutable after listener startup. A callback failure returns `preserve`, so
/// one extension cannot partially apply a batch or corrupt later middleware.
pub const TransformPipeline = struct {
    transformers: [max_transformers]Transformer = undefined,
    len: u8 = 0,

    pub fn add(pipeline: *TransformPipeline, transformer: Transformer) !void {
        if (pipeline.len == pipeline.transformers.len)
            return error.TooManyProxyTransformers;
        pipeline.transformers[pipeline.len] = transformer;
        pipeline.len += 1;
    }

    pub fn apply(
        pipeline: *const TransformPipeline,
        io: std.Io,
        context: TransformContext,
        headers: *Headers,
    ) bool {
        var changed = false;
        for (pipeline.transformers[0..pipeline.len]) |transformer| {
            var view_storage: [max_header_fields]HeaderView = undefined;
            var effects: EffectBatch = .{};
            const status = transformer.transform(
                transformer.context,
                io,
                .{ .context = context, .fields = headers.views(&view_storage) },
                &effects,
            );
            if (status == .preserve or effects.len == 0) continue;
            var candidate: Headers = undefined;
            candidate.copyFrom(headers);
            candidate.apply(effects.effects[0..effects.len]) catch continue;
            headers.copyFrom(&candidate);
            changed = true;
        }
        return changed;
    }
};

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidHeaderName;
    for (name, 0..) |byte, index| {
        if (byte == ':' and index == 0) continue;
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '!' and byte != '#' and byte != '$' and byte != '%' and
            byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
            byte != '-' and byte != '.' and byte != '^' and byte != '_' and
            byte != '`' and byte != '|' and byte != '~')
            return error.InvalidHeaderName;
    }
}

fn validateValue(value: []const u8) !void {
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
    try headers.append(":method", "POST", false);
    try headers.append(":path", "/v1/messages", false);
    try headers.append("authorization", "secret", true);

    var effects: EffectBatch = .{};
    try effects.set(":path", "/v1/responses", false);
    try effects.remove("authorization");
    try effects.set("x-telar", "enabled", false);
    try effects.set("x-order", "first", false);
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
        fn transform(
            _: *anyopaque,
            _: std.Io,
            _: HeaderSnapshot,
            effects: *EffectBatch,
        ) TransformStatus {
            effects.set(":new", "invalid", false) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = TransformerImpl.transform });
    var headers: Headers = .{};
    try headers.append(":method", "GET", false);
    try std.testing.expect(!pipeline.apply(std.testing.io, undefined, &headers));
    try std.testing.expectEqual(@as(u16, 1), headers.len);
    try std.testing.expectEqualStrings("GET", headers.find(":method").?);
}

test "known secret headers remain sensitive regardless of transformer flags" {
    var headers: Headers = .{};
    try headers.append("Authorization", "Bearer secret", false);
    try std.testing.expect(headers.fields[0].sensitive);

    var effects: EffectBatch = .{};
    try effects.set("authorization", "Bearer replacement", false);
    try headers.apply(effects.effects[0..effects.len]);
    try std.testing.expect(headers.fields[0].sensitive);
}
