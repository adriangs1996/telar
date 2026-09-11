const ActivateNotificationHandler = @This();
const client_model = @import("../../root.zig").model;
const ActivationEffects = @import("ActivationEffects.zig");
const InteractionCommand = @import("InteractionCommand.zig");
model: *client_model.Model,
effects: ActivationEffects,

/// Commits an exit transition, rearms time and then follows its target.
///
/// ```zig
/// const activation = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *ActivateNotificationHandler, command: InteractionCommand) !?client_model.NotificationActivation {
    const activation = handler.model.activateNotification(command.id, command.now_ns) orelse return null;

    try handler.effects.timers.reschedule(handler.effects.timers.context);
    switch (activation.target) {
        .none => {},
        else => try handler.effects.navigate(handler.effects.context, activation.target),
    }
    return activation;
}
