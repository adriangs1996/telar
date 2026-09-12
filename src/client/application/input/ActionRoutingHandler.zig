const ActionRoutingEffects = @import("ActionRoutingEffects.zig");
const action = @import("../../input/action.zig");
const action_routing = @import("action_routing.zig");
const lua_action = @import("lua_action.zig");
const ActionRoutingHandler = @This();

effects: ActionRoutingEffects,

/// Routes one configured action without exposing source-specific policy to
/// the host input entrypoint.
///
/// ```zig
/// const control = try handler.execute(action, authority);
/// ```
pub fn execute(self: *ActionRoutingHandler, value: action.Action, authority: action_routing.Authority) !action_routing.Control {
    const available = switch (authority) {
        .suppressed => return .continue_routing,
        .available => |state| state,
    };

    return switch (value) {
        .lua_callback => |reference| self.executeLua(
            .{ .callback = reference },
            available.copy_mode_active,
        ),
        .lua_expr => |reference| self.executeLua(
            .{ .expression = reference },
            available.copy_mode_active,
        ),
        .plugin => |requested| plugin: {
            try self.effects.plugin(self.effects.context, requested);

            break :plugin .continue_routing;
        },
        else => self.effects.native(self.effects.context, value),
    };
}

fn executeLua(handler: *ActionRoutingHandler, command: lua_action.Command, copy_mode_active: bool) !action_routing.Control {
    const outcome = try handler.effects.lua(handler.effects.context, command);

    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key_value| {
                try handler.effects.key(handler.effects.context, key_value);
            },
            .paste => |paste| {
                if (!copy_mode_active) {
                    try handler.effects.paste(handler.effects.context, paste.slice());
                }
            },
        },
    }

    return .continue_routing;
}
