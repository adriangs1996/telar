const Key = @import("telar-client").Key;
const Input = @This();

code: Key.Code,
mods: @import("Modifiers.zig").Modifiers = .{},
phase: Key.Phase = .press,
physical: ?Key.Physical = null,
kitty: ?Key.KittyCodepoints = null,
target_id: u64 = 0,
generation: u64 = 0,

/// Converts only after GUI shortcuts have been handled. Super has no terminal
/// encoding in the shared key protocol. Example: `router.route(key.terminalKey());`
pub fn terminalKey(key: Input) Key {
    return .{ .code = key.code, .mods = .{ .shift = key.mods.shift, .alt = key.mods.alt, .ctrl = key.mods.ctrl }, .phase = key.phase, .physical = key.physical, .kitty = key.kitty };
}

/// Example: `const input = KeyInput.fromTerminal(recovered);`
pub fn fromTerminal(key: Key) Input {
    return .{ .code = key.code, .mods = .{ .shift = key.mods.shift, .alt = key.mods.alt, .ctrl = key.mods.ctrl }, .phase = key.phase, .physical = key.physical, .kitty = key.kitty };
}
