const middleware = @import("middleware.zig");
const HeaderView = @import("HeaderView.zig");
/// Storage is owned by the callback invocation. Future worker adapters copy
/// the completed batch before returning it to the tunnel actor.
const EffectBatch = @This();

effects: [middleware.max_effects]middleware.Effect = undefined,
len: u8 = 0,
bytes: [middleware.max_effect_bytes]u8 = undefined,
bytes_len: usize = 0,

pub fn remove(self: *EffectBatch, name: []const u8) !void {
    const owned_name = try self.copy(name);
    try self.append(.{ .remove = .{ .name = owned_name } });
}

/// Adds one owned header replacement to the atomic effect batch.
///
/// ```zig
/// try effects.set(.{ .name = "x-telar", .value = "enabled" });
/// ```
pub fn set(self: *EffectBatch, header: HeaderView) !void {
    const owned_name = try self.copy(header.name);
    const owned_value = try self.copy(header.value);
    try self.append(.{ .set = .{
        .name = owned_name,
        .value = owned_value,
        .sensitive = header.sensitive,
    } });
}

fn append(self: *EffectBatch, effect: middleware.Effect) !void {
    if (self.len == self.effects.len) {
        return error.TooManyHeaderEffects;
    }
    self.effects[self.len] = effect;
    self.len += 1;
}

fn copy(self: *EffectBatch, value: []const u8) ![]const u8 {
    if (value.len > self.bytes.len - self.bytes_len) {
        return error.HeaderEffectsTooLarge;
    }
    const start = self.bytes_len;
    @memcpy(self.bytes[start..][0..value.len], value);
    self.bytes_len += value.len;
    return self.bytes[start..self.bytes_len];
}
