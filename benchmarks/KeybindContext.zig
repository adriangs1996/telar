const KeybindContext = @This();
const source_namespace = @import("main.zig");
const frontend = @import("telar-frontend");
router: source_namespace.KeybindRouter,
checksum: u64 = 0,

fn init() !KeybindContext {
    const ctrl_b = try frontend.keybind.parseKey("ctrl+b");
    const d = try frontend.keybind.parseKey("d");
    const p = try frontend.keybind.parseKey("p");
    var bindings: [2]source_namespace.KeybindBinding = undefined;
    bindings[0] = try .init(&.{ ctrl_b, d }, .detach);
    bindings[1] = try .init(&.{ ctrl_b, p }, .palette);
    return .{ .router = try .init(&bindings) };
}

pub fn forward(context: *KeybindContext, bytes: []const u8) !void {
    context.checksum +%= bytes.len;
    if (bytes.len != 0) {
        context.checksum +%= bytes[0];
    }
}

pub fn action(context: *KeybindContext, action_value: source_namespace.KeybindAction) !frontend.keybind.Control {
    context.checksum +%= @intFromEnum(action_value) + 1;
    return .continue_routing;
}
