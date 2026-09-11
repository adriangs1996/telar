const lua_action = @import("lua_action.zig");
const CallbackContextType = @import("../../config/CallbackContext.zig");
const ModelType = @import("../../model/Model.zig");
const effects = @import("../../config/effects.zig");
const action = @import("../../input/action.zig");
const LuaActionEffects = @import("LuaActionEffects.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const Capture = @This();

invocation: lua_action.Invocation,
validation: lua_action.Validation = .valid,
invoke_calls: usize = 0,
validate_calls: usize = 0,
apply_calls: usize = 0,
exit_after: ?usize = null,
observed_context: CallbackContextType = undefined,
diagnostic_cleared_before_apply: bool = true,
model: *const ModelType,
applied: [effects.max_callback_effects]action.Action = undefined,

pub fn port(capture: *Capture) LuaActionEffects {
    return .{
        .context = capture,
        .invoke = invoke,
        .validate = validate,
        .apply = apply,
    };
}

fn invoke(raw_context: *anyopaque, command: lua_action.Command, context: CallbackContextType) lua_action.Invocation {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = command;
    capture.invoke_calls += 1;
    capture.observed_context = context;
    return capture.invocation;
}

fn validate(raw_context: *anyopaque, batch: *const EffectBatchType) lua_action.Validation {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    _ = batch;
    capture.validate_calls += 1;
    return capture.validation;
}

fn apply(raw_context: *anyopaque, effect: action.Action) !lua_action.Disposition {
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
