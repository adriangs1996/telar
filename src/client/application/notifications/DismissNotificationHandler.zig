const DismissNotificationHandler = @This();
const client_model = @import("../../root.zig").model;
const TimerEffects = @import("TimerEffects.zig");
const InteractionCommand = @import("InteractionCommand.zig");
model: *client_model.Model,
effects: TimerEffects,

/// Commits an exit transition without activating the notification.
///
/// ```zig
/// const change = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *DismissNotificationHandler, command: InteractionCommand) !?client_model.NotificationChange {
    const change = handler.model.dismissNotification(command.id, command.now_ns) orelse return null;

    try handler.effects.reschedule(handler.effects.context);
    return change;
}
