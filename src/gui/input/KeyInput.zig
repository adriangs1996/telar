const Modifiers = @import("Modifiers.zig");
const data = @import("model");
const Input = @This();

code: data.Key.Code,
mods: Modifiers.Modifiers = .{},
phase: data.Key.Phase = .press,
physical: ?data.Key.Physical = null,
kitty: ?data.Key.KittyCodepoints = null,
target_id: u64 = 0,
generation: u64 = 0,

/// Converts only after GUI shortcuts have been handled. Super has no terminal
/// encoding in the shared key protocol. Example: `router.route(key.terminalKey());`
pub fn terminalKey(key: Input) data.Key {
    return .{ .code = key.code, .mods = .{ .shift = key.mods.shift, .alt = key.mods.alt, .ctrl = key.mods.ctrl }, .phase = key.phase, .physical = key.physical, .kitty = key.kitty };
}
