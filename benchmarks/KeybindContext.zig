const keyinput = @import("keyinput");
const main = @import("main.zig");
const KeybindContext = @This();

router: main.KeybindRouter,
/// The typed text, then ctrl+b and d.
keys: [main.keybind_keys.len + 2]keyinput.Key,
checksum: u64 = 0,

pub fn init() !KeybindContext {
    const ctrl_b = try keyinput.chord.parseKey("ctrl+b");
    const d = try keyinput.chord.parseKey("d");
    const p = try keyinput.chord.parseKey("p");
    var bindings: [2]main.KeybindBinding = undefined;
    bindings[0] = try .init(&.{ ctrl_b, d }, .detach);
    bindings[1] = try .init(&.{ ctrl_b, p }, .palette);

    var keys: [main.keybind_keys.len + 2]keyinput.Key = undefined;
    for (main.keybind_keys, 0..) |byte, index| {
        keys[index] = .{ .code = .{ .char = keyinput.Char.init(&.{byte}) } };
    }

    keys[main.keybind_keys.len] = ctrl_b;
    keys[main.keybind_keys.len + 1] = d;
    return .{ .router = try .init(&bindings), .keys = keys };
}
