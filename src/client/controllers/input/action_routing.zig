//! Wires configured actions to native, Lua, plugin and semantic input ports.

const Client = @import("../../AttachedClient.zig");
const Action = @import("../../input/action.zig").Action;
const ControlType = @import("../../input/keybind.zig").Control;
const ActionRoutingContext = @import("ActionRoutingContext.zig");
const ActionRoutingHandlerType = @import("../../application/input/ActionRoutingHandler.zig");
const ApplicationInputActionRoutingAuthority = @import("../../application/input/action_routing.zig").Authority;
const RepeatPolicyType = @import("../../input/RepeatPolicy.zig");
const key_routing = @import("key_routing.zig");
const repeatPolicy_module = @import("../../application/input/action_routing.zig").repeatPolicy;
const ApplicationInputActionRoutingControl = @import("../../application/input/action_routing.zig").Control;
const client_actions = @import("actions.zig");
const ApplicationInputLuaActionCommand = @import("../../application/input/lua_action.zig").Command;
const ApplicationInputLuaActionOutcome = @import("../../application/input/lua_action.zig").Outcome;
const lua_actions = @import("../configuration/lua_actions.zig");
const PluginAction = @import("../../input/PluginAction.zig");
const plugin_actions = @import("../configuration/plugin_actions.zig");
const KeyType = @import("../../input/Key.zig");
const pane_inputs = @import("pane_inputs.zig");

/// Routes one configured action through native, Lua or plugin policy.
///
/// ```zig
/// return try apply(client, action);
/// ```
pub fn apply(client: *Client, value: Action) !ControlType {
    var context: ActionRoutingContext = .{ .client = client };

    var use_case: ActionRoutingHandlerType = .{
        .effects = .{
            .context = &context,
            .native = native,
            .lua = lua,
            .plugin = plugin,
            .key = key,
            .paste = paste,
        },
    };

    const authority: ApplicationInputActionRoutingAuthority = if (client.model.name_prompt.active())
        .suppressed
    else
        .{
            .available = .{
                .copy_mode_active = client.model.copyModeActive(),
            },
        };
    const control = try use_case.execute(value, authority);

    return switch (control) {
        .continue_routing => .continue_routing,
        .stop => .stop,
    };
}

/// Resolves repeat authority without retaining pane storage.
/// For example: `const policy = repeatPolicy(client, action);`.
pub fn repeatPolicy(client: *const Client, value: Action) ?RepeatPolicyType {
    if (key_routing.captures(client)) {
        return null;
    }

    const target = client.model.planPaneInput(.focused) orelse return null;

    return repeatPolicy_module(value, target.pane_id);
}

fn native(raw_context: *anyopaque, value: Action) !ApplicationInputActionRoutingControl {
    const context: *ActionRoutingContext = @ptrCast(@alignCast(raw_context));

    return switch (try client_actions.apply(context.client, value)) {
        .continue_routing => .continue_routing,
        .stop => .stop,
    };
}

fn lua(raw_context: *anyopaque, command: ApplicationInputLuaActionCommand) !ApplicationInputLuaActionOutcome {
    const context: *ActionRoutingContext = @ptrCast(@alignCast(raw_context));

    return lua_actions.execute(context.client, command);
}

fn plugin(raw_context: *anyopaque, requested: PluginAction) !void {
    const context: *ActionRoutingContext = @ptrCast(@alignCast(raw_context));

    _ = try plugin_actions.start(
        context.client,
        requested,
        context.client.model.callbackContext(),
    );
}

fn key(raw_context: *anyopaque, value: KeyType) !void {
    const context: *ActionRoutingContext = @ptrCast(@alignCast(raw_context));
    _ = try key_routing.apply(context.client, .{ .key = value });
}

fn paste(raw_context: *anyopaque, text: []const u8) !void {
    const context: *ActionRoutingContext = @ptrCast(@alignCast(raw_context));

    _ = try pane_inputs.expressionPaste(context.client, text);
}
