const Effects = @This();
const source_namespace = @import("lua_action.zig");
const lua_config = @import("../../config/root.zig");
context: *anyopaque,
invoke: *const fn (*anyopaque, source_namespace.Command, lua_config.CallbackContext) source_namespace.Invocation,
validate: *const fn (*anyopaque, *const lua_config.EffectBatch) source_namespace.Validation,
apply: *const fn (*anyopaque, source_namespace.Action) anyerror!source_namespace.Disposition,
