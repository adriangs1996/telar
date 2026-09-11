const lua_action = @import("lua_action.zig");
const CallbackContextType = @import("../../config/CallbackContext.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const action = @import("../../input/action.zig");
const Effects = @This();

context: *anyopaque,
invoke: *const fn (*anyopaque, lua_action.Command, CallbackContextType) lua_action.Invocation,
validate: *const fn (*anyopaque, *const EffectBatchType) lua_action.Validation,
apply: *const fn (*anyopaque, action.Action) anyerror!lua_action.Disposition,
