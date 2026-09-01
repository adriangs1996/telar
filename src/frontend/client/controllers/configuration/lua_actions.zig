//! Adapts the client-owned Lua generation to semantic application actions.

const lua_config = @import("../../../config/root.zig");
const input = @import("../../../input/root.zig");
const input_application = @import("../../application/input/root.zig");

const Client = @import("../../client.zig");
const client_actions = @import("../input/actions.zig");
const plugin_actions = @import("plugin_actions.zig");
const lua_action = input_application.lua_action;

pub const Command = lua_action.Command;
pub const Outcome = lua_action.Outcome;

const EvaluationContext = struct {
    client: *Client,
    diagnostic: lua_config.Diagnostic = .{},
};

/// Evaluates one configured Lua action against a model value snapshot.
///
/// ```zig
/// const outcome = try execute(client, command);
/// ```
pub fn execute(client: *Client, command: Command) !Outcome {
    var context: EvaluationContext = .{ .client = client };
    var use_case: lua_action.LuaActionHandler = .{
        .model = &client.model,
        .effects = .{
            .context = &context,
            .invoke = invoke,
            .validate = validate,
            .apply = apply,
        },
    };

    return use_case.execute(command);
}

fn invoke(raw_context: *anyopaque, command: Command, callback_context: lua_config.CallbackContext) lua_action.Invocation {
    const context: *EvaluationContext = @ptrCast(@alignCast(raw_context));
    const generation = context.client.lua_generation orelse return .unavailable;

    return switch (command) {
        .callback => |reference| if (generation.invokeCallback(
            reference,
            callback_context,
            &context.diagnostic,
        )) |batch|
            .{ .callback = batch }
        else |err|
            invocationFailure(context, err),
        .expression => |reference| if (generation.invokeExpression(
            reference,
            callback_context,
            &context.diagnostic,
        )) |decision|
            .{ .expression = decision }
        else |err|
            invocationFailure(context, err),
    };
}

fn validate(raw_context: *anyopaque, batch: *const lua_config.EffectBatch) lua_action.Validation {
    const context: *EvaluationContext = @ptrCast(@alignCast(raw_context));
    for (batch.slice()) |effect| {
        switch (effect) {
            .plugin => |requested| {
                const registry = context.client.plugin_registry orelse {
                    context.diagnostic.set(
                        "Lua callback referenced a plugin but no registry is active",
                        .{},
                    );
                    return validationFailure(context, error.PluginRegistryUnavailable);
                };
                _ = registry.resolve(requested) catch |err| {
                    context.diagnostic.set(
                        "Lua callback returned an invalid plugin action: {s}",
                        .{@errorName(err)},
                    );
                    return validationFailure(context, err);
                };
            },
            .lua_callback, .lua_expr => {
                context.diagnostic.set("Lua callback returned a recursive Lua action", .{});
                return validationFailure(context, error.InvalidCallbackResult);
            },
            else => {},
        }
    }

    return .valid;
}

fn apply(raw_context: *anyopaque, effect: input.action.Action) !lua_action.Disposition {
    const context: *EvaluationContext = @ptrCast(@alignCast(raw_context));
    return switch (effect) {
        .plugin => |requested| plugin: {
            _ = try plugin_actions.start(
                context.client,
                requested,
                context.client.model.callbackContext(),
            );
            break :plugin .continue_client;
        },
        .lua_callback, .lua_expr => error.InvalidCallbackResult,
        else => switch (try client_actions.apply(context.client, effect)) {
            .continue_routing => .continue_client,
            .stop => .exit_client,
        },
    };
}

fn invocationFailure(context: *EvaluationContext, reason: anyerror) lua_action.Invocation {
    if (context.diagnostic.len == 0) {
        context.diagnostic.set("Lua action failed: {s}", .{@errorName(reason)});
    }

    return .{ .failed = .{
        .reason = reason,
        .diagnostic = context.diagnostic,
    } };
}

fn validationFailure(context: *EvaluationContext, reason: anyerror) lua_action.Validation {
    return .{ .failed = .{
        .reason = reason,
        .diagnostic = context.diagnostic,
    } };
}
