const ModelType = @import("../../model/Model.zig");
const PluginActionStartEffects = @import("PluginActionStartEffects.zig");
const StartDelivery = @import("StartDelivery.zig");
const plugin_action = @import("plugin_action.zig");
const std = @import("std");
const StartPluginActionHandler = @This();

model: *ModelType,
effects: PluginActionStartEffects,
delivery: StartDelivery,

/// Prepares one invocation, starts its worker under one committed identity,
/// then delivers the classified start outcome.
///
/// ```zig
/// const outcome = try handler.execute();
/// ```
pub fn execute(handler: *StartPluginActionHandler) !plugin_action.StartOutcome {
    if (handler.model.pluginExecution() != null) {
        return handler.deliver(.busy);
    }

    handler.effects.prepare(handler.effects.context) catch |err| switch (err) {
        error.PluginRegistryUnavailable => return handler.deliver(.unavailable),
        error.PluginNotConfigured, error.UnknownPluginAction => return handler.deliver(.{ .rejected = err }),
        else => return err,
    };
    const execution = (try handler.model.beginPluginExecution()) orelse
        return handler.deliver(.busy);
    {
        errdefer {
            const rolled_back = handler.model.finishPluginExecution(execution.id);
            std.debug.assert(rolled_back != null);
        }

        try handler.effects.schedule(handler.effects.context, execution);
    }

    return handler.deliver(.{ .started = execution });
}

fn deliver(handler: *StartPluginActionHandler, outcome: plugin_action.StartOutcome) !plugin_action.StartOutcome {
    try handler.delivery.deliver(handler.delivery.context, outcome);

    return outcome;
}
