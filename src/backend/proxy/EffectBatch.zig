const middleware = @import("middleware.zig");
const HeaderView = @import("HeaderView.zig");
/// Storage is owned by the callback invocation. Future worker adapters copy
/// the completed batch before returning it to the tunnel actor.
const EffectBatch = @This();

effects: [middleware.max_effects]middleware.Effect = undefined,
len: u8 = 0,
bytes: [middleware.max_effect_bytes]u8 = undefined,
bytes_len: usize = 0,

pub fn remove(batch: *EffectBatch, name: []const u8) !void {
    const owned_name = try batch.copy(name);
    try batch.append(.{ .remove = .{ .name = owned_name } });
}

/// Adds one owned header replacement to the atomic effect batch.
///
/// ```zig
/// try effects.set(.{ .name = "x-telar", .value = "enabled" });
/// ```
pub fn set(batch: *EffectBatch, header: HeaderView) !void {
    const owned_name = try batch.copy(header.name);
    const owned_value = try batch.copy(header.value);
    try batch.append(.{ .set = .{
        .name = owned_name,
        .value = owned_value,
        .sensitive = header.sensitive,
    } });
}

fn append(batch: *EffectBatch, effect: middleware.Effect) !void {
    if (batch.len == batch.effects.len) {
        return error.TooManyHeaderEffects;
    }
    batch.effects[batch.len] = effect;
    batch.len += 1;
}

fn copy(batch: *EffectBatch, value: []const u8) ![]const u8 {
    if (value.len > batch.bytes.len - batch.bytes_len) {
        return error.HeaderEffectsTooLarge;
    }
    const start = batch.bytes_len;
    @memcpy(batch.bytes[start..][0..value.len], value);
    batch.bytes_len += value.len;
    return batch.bytes[start..batch.bytes_len];
}
