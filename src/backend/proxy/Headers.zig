const middleware = @import("middleware.zig");
const HeaderField = @import("HeaderField.zig");
const HeaderView = @import("HeaderView.zig");
const std = @import("std");
/// Fixed owned header storage. Offsets remain valid when the value moves.
const Headers = @This();

fields: [middleware.max_header_fields]HeaderField = undefined,
len: u16 = 0,
bytes: [middleware.max_header_bytes]u8 = undefined,
bytes_len: usize = 0,

/// Copies one validated header into bounded owned storage.
///
/// ```zig
/// try headers.append(.{ .name = "content-type", .value = "text/event-stream" });
/// ```
pub fn append(headers: *Headers, header: HeaderView) !void {
    const header_name = header.name;
    const header_value = header.value;

    try middleware.validateName(header_name);
    try middleware.validateValue(header_value);
    if (headers.len == headers.fields.len) {
        return error.TooManyHeaders;
    }
    if (header_name.len + header_value.len > headers.bytes.len - headers.bytes_len) {
        return error.HeadersTooLarge;
    }
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
        .sensitive = header.sensitive or middleware.isSensitiveName(header_name),
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

pub fn views(headers: *const Headers, storage: *[middleware.max_header_fields]HeaderView) []const HeaderView {
    for (headers.fields[0..headers.len], 0..) |field, index| storage[index] = .{
        .name = headers.name(field),
        .value = headers.value(field),
        .sensitive = field.sensitive,
    };
    return storage[0..headers.len];
}

pub fn apply(headers: *Headers, effects: []const middleware.Effect) !void {
    if (effects.len == 0) {
        return;
    }
    var replacement: Headers = .{};
    var inserted: [middleware.max_effects]bool = @splat(false);

    for (headers.fields[0..headers.len]) |field| {
        const field_name = headers.name(field);
        var last_match: ?usize = null;
        for (effects, 0..) |effect, effect_index| {
            if (std.ascii.eqlIgnoreCase(field_name, middleware.effectName(effect))) {
                last_match = effect_index;
            }
        }
        if (last_match) |effect_index| {
            switch (effects[effect_index]) {
                .remove => {},
                .set => |set_effect| if (!inserted[effect_index]) {
                    try replacement.append(.{
                        .name = set_effect.name,
                        .value = set_effect.value,
                        .sensitive = set_effect.sensitive,
                    });
                    inserted[effect_index] = true;
                },
            }
        } else {
            try replacement.append(.{
                .name = field_name,
                .value = headers.value(field),
                .sensitive = field.sensitive,
            });
        }
    }

    // New pseudo-headers must precede regular headers. Effects that replace
    // an existing pseudo-header were inserted in its original position.
    for (effects, 0..) |effect, effect_index| switch (effect) {
        .remove => {},
        .set => |set_effect| if (!inserted[effect_index]) {
            var superseded = false;
            for (effects[effect_index + 1 ..]) |later|
                if (std.ascii.eqlIgnoreCase(set_effect.name, middleware.effectName(later))) {
                    superseded = true;
                    break;
                };
            if (superseded) {
                continue;
            }
            if (set_effect.name.len != 0 and set_effect.name[0] == ':') {
                return error.CannotInsertPseudoHeader;
            }
            try replacement.append(.{
                .name = set_effect.name,
                .value = set_effect.value,
                .sensitive = set_effect.sensitive,
            });
        },
    };
    headers.copyFrom(&replacement);
}
