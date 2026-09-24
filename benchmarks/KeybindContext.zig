const keyinput = @import("keyinput");
const main = @import("main.zig");
const KeybindContext = @This();

router: main.KeybindRouter,
checksum: u64 = 0,

pub fn init() !KeybindContext {
    const ctrl_b = try keyinput.chord.parseKey("ctrl+b");
    const d = try keyinput.chord.parseKey("d");
    const p = try keyinput.chord.parseKey("p");
    var bindings: [2]main.KeybindBinding = undefined;
    bindings[0] = try .init(&.{ ctrl_b, d }, .detach);
    bindings[1] = try .init(&.{ ctrl_b, p }, .palette);
    return .{ .router = try .init(&bindings) };
}
