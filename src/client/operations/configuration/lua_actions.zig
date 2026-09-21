//! Adapts the client-owned Lua generation to semantic application actions.

const Failure = @import("../../application/input/Failure.zig");
const client_diagnostic = @import("../../application/configuration/client_diagnostic.zig");
const Client = @import("../../AttachedClient.zig");
const ApplicationInputLuaActionCommand = @import("../../application/input/lua_action.zig").Command;
const ApplicationInputLuaActionOutcome = @import("../../application/input/lua_action.zig").Outcome;
const EvaluationContext = @import("EvaluationContext.zig");
const CallbackContextType = @import("../../config/CallbackContext.zig");
const InvocationType = @import("../../application/input/lua_action.zig").Invocation;
const EffectBatchType = @import("../../config/EffectBatch.zig");
const ValidationType = @import("../../application/input/lua_action.zig").Validation;
const ActionType = @import("../../input/action.zig").Action;
const DispositionType = @import("../../application/input/lua_action.zig").Disposition;
const plugin_actions = @import("plugin_actions.zig");
const client_actions = @import("../input/actions.zig");

/// Evaluates one configured Lua action against a model value snapshot.
///
/// ```zig
/// const outcome = try execute(client, command);
/// ```
pub fn execute(client: *Client, command: ApplicationInputLuaActionCommand) !ApplicationInputLuaActionOutcome {
    var context: EvaluationContext = .{ .client = client };
    const invocation = invoke(&context, command, client.model.callbackContext());

    return switch (invocation) {
        .unavailable => .unavailable,
        .failed => |failure| failed: {
            try publishFailure(client, failure);
            break :failed .{ .invocation_failed = failure.reason };
        },
        .expression => |decision| expression: {
            _ = client.model.clearDiagnostic();
            break :expression .{ .input = decision };
        },
        .callback => |batch| callback: {
            switch (validate(&context, &batch)) {
                .valid => {},
                .failed => |failure| {
                    try publishFailure(client, failure);
                    break :callback .{ .validation_failed = failure.reason };
                },
            }

            _ = client.model.clearDiagnostic();
            for (batch.slice()) |effect| {
                if (try apply(&context, effect) == .exit_client) {
                    break :callback .exit;
                }
            }

            break :callback .applied;
        },
    };
}

fn invoke(context: *EvaluationContext, command: ApplicationInputLuaActionCommand, callback_context: CallbackContextType) InvocationType {
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

fn validate(context: *EvaluationContext, batch: *const EffectBatchType) ValidationType {
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

fn apply(context: *EvaluationContext, effect: ActionType) !DispositionType {
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

fn publishFailure(client: *Client, failure: Failure) !void {
    _ = try client_diagnostic.replace(&client.model, .{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "Lua action failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });
}
