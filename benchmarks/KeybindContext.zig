const main = @import("main.zig");
const parseKey_module = @import("telar-client").parseKey;
const ControlType = @import("telar-client").Control;
const KeybindContext = @This();

router: main.KeybindRouter,
checksum: u64 = 0,

pub fn init() !KeybindContext {
    const ctrl_b = try parseKey_module("ctrl+b");
    const d = try parseKey_module("d");
    const p = try parseKey_module("p");
    var bindings: [2]main.KeybindBinding = undefined;
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

pub fn action(context: *KeybindContext, action_value: main.KeybindAction) !ControlType {
    context.checksum +%= @intFromEnum(action_value) + 1;
    return .continue_routing;
}
