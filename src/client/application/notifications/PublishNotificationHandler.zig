const PublishNotificationHandler = @This();
const client_model = @import("../../root.zig").model;
const TimerEffects = @import("TimerEffects.zig");
const PublishCommand = @import("PublishCommand.zig");
model: *client_model.Model,
effects: TimerEffects,

/// Commits owned notification state before rearming its lifecycle timer.
///
/// ```zig
/// const publication = try handler.execute(command);
/// ```
pub fn execute(handler: *PublishNotificationHandler, command: PublishCommand) !client_model.NotificationPublication {
    const publication = handler.model.publishNotification(command.now_ns, command.input);

    try handler.effects.reschedule(handler.effects.context);
    return publication;
}
