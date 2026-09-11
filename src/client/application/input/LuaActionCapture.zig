const Capture = @This();
const source_namespace = @import("lua_action.zig");
const lua_config = @import("../../config/root.zig");
const client_model = @import("../../root.zig").model;
const Effects = @import("LuaActionEffects.zig");
invocation: source_namespace.Invocation,
validation: source_namespace.Validation = .valid,
invoke_calls: usize = 0,
validate_calls: usize = 0,
apply_calls: usize = 0,
exit_after: ?usize = null,
observed_context: lua_config.CallbackContext = undefined,
diagnostic_cleared_before_apply: bool = true,
model: *const client_model.Model,
applied: [lua_config.max_callback_effects]source_namespace.Action = undefined,

pub fn port(capture: *Capture) Effects {
    return .{
        .context = capture,
        .invoke = invoke,
        .validate = validate,
        .apply = apply,
    };
}

fn invoke(raw_context: *anyopaque, command: source_namespace.Command, context: lua_config.CallbackContext) source_namespace.Invocation {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.invoke_calls += 1;
    capture.observed_context = context;
    return capture.invocation;
}

fn validate(raw_context: *anyopaque, batch: *const lua_config.EffectBatch) source_namespace.Validation {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = batch;
    capture.validate_calls += 1;
    return capture.validation;
}

fn apply(raw_context: *anyopaque, effect: source_namespace.Action) !source_namespace.Disposition {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.diagnostic_cleared_before_apply = capture.diagnostic_cleared_before_apply and
        capture.model.diagnostic() == null;
    capture.applied[capture.apply_calls] = effect;
    capture.apply_calls += 1;
    if (capture.exit_after) |index| {
        if (capture.apply_calls == index) {
            return .exit_client;
        }
    }

    return .continue_client;
}
