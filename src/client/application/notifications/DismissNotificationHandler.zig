const ModelType = @import("../../model/Model.zig");
const TimerEffects = @import("TimerEffects.zig");
const InteractionCommand = @import("InteractionCommand.zig");
const NotificationChangeType = @import("../../model/NotificationChange.zig");
const DismissNotificationHandler = @This();

model: *ModelType,
effects: TimerEffects,

/// Commits an exit transition without activating the notification.
///
/// ```zig
/// const change = try handler.execute(command) orelse return;
/// ```
pub fn execute(handler: *DismissNotificationHandler, command: InteractionCommand) !?NotificationChangeType {
    const change = handler.model.dismissNotification(command.id, command.now_ns) orelse return null;

    try handler.effects.reschedule(handler.effects.context);
    return change;
}
