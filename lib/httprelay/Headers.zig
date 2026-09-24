const header_rules = @import("header_rules.zig");
const HeaderField = @import("HeaderField.zig");
const HeaderView = @import("HeaderView.zig");
const std = @import("std");
/// Fixed owned header storage. Offsets remain valid when the value moves.
const Headers = @This();

fields: [header_rules.max_header_fields]HeaderField = undefined,
len: u16 = 0,
bytes: [header_rules.max_header_bytes]u8 = undefined,
bytes_len: usize = 0,

/// Copies one validated header into bounded owned storage.
///
/// ```zig
/// try headers.append(.{ .name = "content-type", .value = "text/event-stream" });
/// ```
pub fn append(self: *Headers, header: HeaderView) !void {
    const header_name = header.name;
    const header_value = header.value;

    try header_rules.validateName(header_name);
    try header_rules.validateValue(header_value);
    if (self.len == self.fields.len) {
        return error.TooManyHeaders;
    }
    if (header_name.len + header_value.len > self.bytes.len - self.bytes_len) {
        return error.HeadersTooLarge;
    }
    const name_start = self.bytes_len;
    @memcpy(self.bytes[name_start..][0..header_name.len], header_name);
    self.bytes_len += header_name.len;
    const value_start = self.bytes_len;
    @memcpy(self.bytes[value_start..][0..header_value.len], header_value);
    self.bytes_len += header_value.len;
    self.fields[self.len] = .{
        .name_start = @intCast(name_start),
        .name_len = @intCast(header_name.len),
        .value_start = @intCast(value_start),
        .value_len = @intCast(header_value.len),
        .sensitive = header.sensitive or header_rules.isSensitiveName(header_name),
    };
    self.len += 1;
}

pub fn name(self: *const Headers, field: HeaderField) []const u8 {
    return self.bytes[field.name_start..][0..field.name_len];
}

pub fn value(self: *const Headers, field: HeaderField) []const u8 {
    return self.bytes[field.value_start..][0..field.value_len];
}

pub fn find(self: *const Headers, wanted: []const u8) ?[]const u8 {
    for (self.fields[0..self.len]) |field|
        if (std.ascii.eqlIgnoreCase(self.name(field), wanted))
            return self.value(field);
    return null;
}

pub fn copyFrom(self: *Headers, source: *const Headers) void {
    self.len = source.len;
    self.bytes_len = source.bytes_len;
    @memcpy(
        self.fields[0..source.len],
        source.fields[0..source.len],
    );
    @memcpy(
        self.bytes[0..source.bytes_len],
        source.bytes[0..source.bytes_len],
    );
}

pub fn views(self: *const Headers, storage: *[header_rules.max_header_fields]HeaderView) []const HeaderView {
    for (self.fields[0..self.len], 0..) |field, index| storage[index] = .{
        .name = self.name(field),
        .value = self.value(field),
        .sensitive = field.sensitive,
    };
    return storage[0..self.len];
}

pub fn apply(self: *Headers, effects: []const header_rules.Effect) !void {
    if (effects.len == 0) {
        return;
    }

    if (effects.len > header_rules.max_effects) {
        return error.TooManyHeaderEffects;
    }

    var replacement: Headers = .{};
    var inserted: [header_rules.max_effects]bool = @splat(false);

    for (self.fields[0..self.len]) |field| {
        const field_name = self.name(field);
        var last_match: ?usize = null;
        for (effects, 0..) |effect, effect_index| {
            if (std.ascii.eqlIgnoreCase(field_name, header_rules.effectName(effect))) {
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
                .value = self.value(field),
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
                if (std.ascii.eqlIgnoreCase(set_effect.name, header_rules.effectName(later))) {
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
    self.copyFrom(&replacement);
}
