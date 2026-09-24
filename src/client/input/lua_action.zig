//! Lua actions: evaluates a Lua binding and applies the effects it returns.
const keyinput = @import("keyinput");
const data = @import("model");
const lua_diagnostics = @import("../config/lua_actions.zig");
const client_diagnostic = @import("../config/client_diagnostic.zig");
const actions = @import("actions.zig");
const copy_mode = @import("copy_mode.zig");
const key_routing = @import("key_routing.zig");
const pane_input = @import("../panes/pane_input.zig");
const plugin_actions = @import("../plugins/plugin_actions.zig");
const Client = @import("../execution/Client.zig");

pub fn executeLuaAction(client: *Client, command: data.LuaActionCommand) !keyinput.Control {
    const copy_mode_active = copy_mode.copyModeActive(client);
    const outcome = try evaluateLuaAction(client, command);
    switch (outcome) {
        .applied, .unavailable, .invocation_failed, .validation_failed => return .continue_routing,
        .exit => return .stop,
        .input => |decision| switch (decision) {
            .consume => {},
            .forward_binding, .keys => |keys| for (keys.slice()) |key| {
                _ = try key_routing.routeKeyInput(
                    client,
                    .{
                        .key = key,
                    },
                );
            },
            .paste => |paste| {
                if (!copy_mode_active) {
                    _ = try pane_input.pasteExpression(client, paste.slice());
                }
            },
        },
    }

    return .continue_routing;
}

/// Evaluates one configured Lua action against a model value snapshot.
fn evaluateLuaAction(client: *Client, command: data.LuaActionCommand) !data.LuaActionOutcome {
    var diagnostic: data.Diagnostic = .{};
    const callback_context = client.model.callbackContext();
    const generation = client.lua_generation orelse return .unavailable;

    const invocation: data.LuaInvocation = switch (command) {
        .callback => |reference| if (generation.invokeCallback(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &diagnostic,
        )) |batch|
            .{
                .callback = batch,
            }
        else |err|
            lua_diagnostics.invocationFailure(&diagnostic, err),
        .expression => |reference| if (generation.invokeExpression(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &diagnostic,
        )) |decision|
            .{
                .expression = decision,
            }
        else |err|
            lua_diagnostics.invocationFailure(&diagnostic, err),
    };

    return switch (invocation) {
        .unavailable => .unavailable,
        .failed => |failure| failed: {
            try publishLuaFailure(&client.model, failure);
            break :failed .{
                .invocation_failed = failure.reason,
            };
        },
        .expression => |decision| expression: {
            _ = client.model.clearDiagnostic();
            break :expression .{
                .input = decision,
            };
        },
        .callback => |batch| callback: {
            switch (lua_diagnostics.validateBatch(
                client.plugin_registry,
                &batch,
                &diagnostic,
            )) {
                .valid => {},
                .failed => |failure| {
                    try publishLuaFailure(&client.model, failure);
                    break :callback .{
                        .validation_failed = failure.reason,
                    };
                },
            }

            _ = client.model.clearDiagnostic();
            for (batch.slice()) |effect| {
                if (try applyLuaEffect(client, effect) == .exit_client) {
                    break :callback .exit;
                }
            }

            break :callback .applied;
        },
    };
}

fn applyLuaEffect(client: *Client, effect: data.Action) !data.LuaDisposition {
    return switch (effect) {
        .plugin => |requested| plugin: {
            _ = try plugin_actions.startPluginAction(client, requested, client.model.callbackContext());
            break :plugin .continue_client;
        },
        .lua_callback, .lua_expr => error.InvalidCallbackResult,
        else => switch (try actions.executeAction(client, effect, .effect)) {
            .continue_routing => .continue_client,
            .stop => .exit_client,
        },
    };
}

fn publishLuaFailure(model: *data.ClientModel, failure: data.Failure) !void {
    _ = try client_diagnostic.replace(
        model,
        .{
            .diagnostic = failure.diagnostic,
            .invalid_fallback = client_diagnostic.formatted(
                "Lua action failed: {s}",
                .{
                    @errorName(failure.reason),
                },
            ),
        },
    );
}
