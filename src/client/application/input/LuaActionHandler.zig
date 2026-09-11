const ModelType = @import("../../model/Model.zig");
const LuaActionEffects = @import("LuaActionEffects.zig");
const lua_action = @import("lua_action.zig");
const Failure = @import("Failure.zig");
const client_diagnostic = @import("../configuration/client_diagnostic.zig");
const ClientDiagnosticHandlerType = @import("../configuration/ClientDiagnosticHandler.zig");
const LuaActionHandler = @This();

model: *ModelType,
effects: LuaActionEffects,

/// Evaluates one current Lua action and applies only a fully valid batch.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *LuaActionHandler, command: lua_action.Command) !lua_action.Outcome {
    const invocation = handler.effects.invoke(
        handler.effects.context,
        command,
        handler.model.callbackContext(),
    );

    return switch (invocation) {
        .unavailable => .unavailable,
        .failed => |failure| failed: {
            try handler.publishFailure(failure);
            break :failed .{ .invocation_failed = failure.reason };
        },
        .expression => |decision| expression: {
            var diagnostics = handler.diagnosticHandler();
            _ = diagnostics.clear();
            break :expression .{ .input = decision };
        },
        .callback => |batch| callback: {
            switch (handler.effects.validate(handler.effects.context, &batch)) {
                .valid => {},
                .failed => |failure| {
                    try handler.publishFailure(failure);
                    break :callback .{ .validation_failed = failure.reason };
                },
            }

            var diagnostics = handler.diagnosticHandler();
            _ = diagnostics.clear();
            for (batch.slice()) |effect| {
                if (try handler.effects.apply(handler.effects.context, effect) == .exit_client) {
                    break :callback .exit;
                }
            }

            break :callback .applied;
        },
    };
}

fn publishFailure(handler: *LuaActionHandler, failure: Failure) !void {
    var diagnostics = handler.diagnosticHandler();

    _ = try diagnostics.replace(.{
        .diagnostic = failure.diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "Lua action failed: {s}",
            .{@errorName(failure.reason)},
        ),
    });
}

fn diagnosticHandler(handler: *LuaActionHandler) ClientDiagnosticHandlerType {
    return .{ .model = handler.model };
}
