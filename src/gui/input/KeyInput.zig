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
pub fn terminalKey(self: Input) data.Key {
    return .{ .code = self.code, .mods = .{ .shift = self.mods.shift, .alt = self.mods.alt, .ctrl = self.mods.ctrl }, .phase = self.phase, .physical = self.physical, .kitty = self.kitty };
}
