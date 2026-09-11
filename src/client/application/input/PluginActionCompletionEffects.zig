const PluginResult = @import("PluginResult.zig");
const EffectBatchType = @import("../../config/EffectBatch.zig");
const plugin_action = @import("plugin_action.zig");
const CompletionEffects = @This();

context: *anyopaque,
authorize: *const fn (*anyopaque, PluginResult) anyerror!void,
apply: *const fn (*anyopaque, *const EffectBatchType) anyerror!plugin_action.BatchDisposition,
