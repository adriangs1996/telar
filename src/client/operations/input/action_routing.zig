//! Dispatches configured actions to their concrete native, Lua or plugin operation.

const Client = @import("../../AttachedClient.zig");
const Action = @import("../../input/action.zig").Action;
const ControlType = @import("../../input/keybind.zig").Control;
const RepeatPolicyType = @import("../../input/RepeatPolicy.zig");
const key_routing = @import("key_routing.zig");
const repeatPolicy_module = @import("../../application/input/action_routing.zig").repeatPolicy;
const copy_modes = @import("copy_modes.zig");
const client_actions = @import("actions.zig");
const ApplicationInputLuaActionCommand = @import("../../application/input/lua_action.zig").Command;
const lua_actions = @import("../configuration/lua_actions.zig");
const plugin_actions = @import("../configuration/plugin_actions.zig");
const pane_inputs = @import("pane_inputs.zig");

/// Routes one configured action through native, Lua or plugin policy.
///
/// ```zig
/// return try apply(client, action);
/// ```
pub fn apply(client: *Client, value: Action) !ControlType {
    if (client.model.name_prompt.active()) {
        return .continue_routing;
    }

    return switch (value) {
        .lua_callback => |reference| executeLua(client, .{ .callback = reference }),
        .lua_expr => |reference| executeLua(client, .{ .expression = reference }),
        .plugin => |requested| plugin: {
            _ = try plugin_actions.start(client, requested, client.model.callbackContext());
            break :plugin .continue_routing;
        },
        else => client_actions.apply(client, value),
    };
}

/// Resolves repeat authority without retaining pane storage.
/// For example: `const policy = repeatPolicy(client, action);`.
pub fn repeatPolicy(client: *const Client, value: Action) ?RepeatPolicyType {
    if (key_routing.captures(client) or client.model.copyModeActive()) {
        return null;
    }

    const model = client.model.activeTabModelConst() orelse return null;
    const pane = model.focusedPaneConst() orelse return null;
    if (!pane.attached) {
        return null;
    }

    return repeatPolicy_module(value, pane.id);
}

fn executeLua(client: *Client, command: ApplicationInputLuaActionCommand) !ControlType {
    const copy_mode_active = copy_modes.active(client);
    const outcome = try lua_actions.execute(client, command);
    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key| {
                _ = try key_routing.apply(client, .{ .key = key });
            },
            .paste => |paste| {
                if (!copy_mode_active) {
                    _ = try pane_inputs.expressionPaste(client, paste.slice());
                }
            },
        },
    }

    return .continue_routing;
}
