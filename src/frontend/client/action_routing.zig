//! Wires configured actions to native, Lua, plugin and semantic input ports.

const input = @import("../input/root.zig");
const input_application = @import("application/input/root.zig");
const client_actions = @import("actions.zig");
const key_routing = @import("key_routing.zig");
const lua_actions = @import("lua_actions.zig");
const pane_inputs = @import("pane_inputs.zig");
const plugin_actions = @import("plugin_actions.zig");

const Client = @import("client.zig");
const action_routing = input_application.action_routing;
const lua_action = input_application.lua_action;
const Action = input.action.Action;
const PluginAction = input.action.PluginAction;
const keybind = input.keybind;

const Context = struct {
    client: *Client,
};

/// Routes one configured action through native, Lua or plugin policy.
///
/// ```zig
/// return try apply(client, action);
/// ```
pub fn apply(client: *Client, value: Action) !keybind.Control {
    var context: Context = .{ .client = client };

    var use_case: action_routing.ActionRoutingHandler = .{
        .effects = .{
            .context = &context,
            .native = native,
            .lua = lua,
            .plugin = plugin,
            .key = key,
            .paste = paste,
        },
    };

    const authority: action_routing.Authority = if (client.model.name_prompt.active())
        .suppressed
    else
        .{ .available = .{ .copy_mode_active = client.model.copyModeActive() } };

    const control = try use_case.execute(value, authority);

    return switch (control) {
        .continue_routing => .continue_routing,
        .stop => .stop,
    };
}

fn native(raw_context: *anyopaque, value: Action) !action_routing.Control {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    return switch (try client_actions.apply(context.client, value)) {
        .continue_routing => .continue_routing,
        .stop => .stop,
    };
}

fn lua(raw_context: *anyopaque, command: lua_action.Command) !lua_action.Outcome {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    return lua_actions.execute(context.client, command);
}

fn plugin(raw_context: *anyopaque, requested: PluginAction) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try plugin_actions.start(
        context.client,
        requested,
        context.client.model.callbackContext(),
    );
}

fn key(raw_context: *anyopaque, value: keybind.Key) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    _ = try key_routing.apply(context.client, .{ .key = value });
}

fn paste(raw_context: *anyopaque, text: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try pane_inputs.expressionPaste(context.client, text);
}
