const keyinput = @import("keyinput");
const Modifiers = @import("Modifiers.zig");
const Input = @This();

code: keyinput.Key.Code,
mods: Modifiers.Modifiers = .{},
phase: keyinput.Key.Phase = .press,
physical: ?keyinput.Key.Physical = null,
kitty: ?keyinput.Key.KittyCodepoints = null,
target_id: u64 = 0,
generation: u64 = 0,

/// Preserves every modifier for the shared binding router. Unbound Super keys
/// stay client-owned. Example: `router.route(key.terminalKey());`
pub fn terminalKey(self: Input) keyinput.Key {
    return .{ .code = self.code, .mods = .{ .shift = self.mods.shift, .alt = self.mods.alt, .ctrl = self.mods.ctrl, .super = self.mods.super }, .phase = self.phase, .physical = self.physical, .kitty = self.kitty };
}
