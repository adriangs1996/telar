//! Adapts the client-owned Lua generation to semantic application actions.

const Client = @import("../../Client.zig");
const ApplicationInputLuaActionCommand = @import("telar-client").ApplicationInputLuaActionCommand;
const ApplicationInputLuaActionOutcome = @import("telar-client").ApplicationInputLuaActionOutcome;
const EvaluationContext = @import("EvaluationContext.zig");
const LuaActionHandlerType = @import("telar-client").LuaActionHandler;
const CallbackContextType = @import("telar-client").CallbackContext;
const InvocationType = @import("telar-client").Invocation;
const EffectBatchType = @import("telar-client").EffectBatch;
const ValidationType = @import("telar-client").Validation;
const ActionType = @import("telar-client").Action;
const DispositionType = @import("telar-client").Disposition;
const plugin_actions = @import("plugin_actions.zig");
const client_actions = @import("../input/actions.zig");

/// Evaluates one configured Lua action against a model value snapshot.
///
/// ```zig
/// const outcome = try execute(client, command);
/// ```
pub fn execute(client: *Client, command: ApplicationInputLuaActionCommand) !ApplicationInputLuaActionOutcome {
    var context: EvaluationContext = .{ .client = client };
    var use_case: LuaActionHandlerType = .{
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

fn invoke(raw_context: *anyopaque, command: ApplicationInputLuaActionCommand, callback_context: CallbackContextType) InvocationType {
    const context: *EvaluationContext = @ptrCast(@alignCast(raw_context));
    const generation = context.client.lua_generation orelse return .unavailable;

    return switch (command) {
        .callback => |reference| if (generation.invokeCallback(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &context.diagnostic,
        )) |batch|
            .{ .callback = batch }
        else |err|
            invocationFailure(context, err),
        .expression => |reference| if (generation.invokeExpression(
            .{
                .reference = reference,
                .context = callback_context,
            },
            &context.diagnostic,
        )) |decision|
            .{ .expression = decision }
        else |err|
            invocationFailure(context, err),
    };
}

fn validate(raw_context: *anyopaque, batch: *const EffectBatchType) ValidationType {
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

fn apply(raw_context: *anyopaque, effect: ActionType) !DispositionType {
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

fn invocationFailure(context: *EvaluationContext, reason: anyerror) InvocationType {
    if (context.diagnostic.len == 0) {
        context.diagnostic.set("Lua action failed: {s}", .{@errorName(reason)});
    }

    return .{ .failed = .{
        .reason = reason,
        .diagnostic = context.diagnostic,
    } };
}

fn validationFailure(context: *EvaluationContext, reason: anyerror) ValidationType {
    return .{ .failed = .{
        .reason = reason,
        .diagnostic = context.diagnostic,
    } };
}
