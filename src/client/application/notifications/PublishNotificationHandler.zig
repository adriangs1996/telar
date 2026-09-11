const ModelType = @import("../../model/Model.zig");
const TimerEffects = @import("TimerEffects.zig");
const PublishCommand = @import("PublishCommand.zig");
const NotificationPublicationType = @import("../../model/NotificationPublication.zig");
const PublishNotificationHandler = @This();

model: *ModelType,
effects: TimerEffects,

/// Commits owned notification state before rearming its lifecycle timer.
///
/// ```zig
/// const publication = try handler.execute(command);
/// ```
pub fn execute(handler: *PublishNotificationHandler, command: PublishCommand) !NotificationPublicationType {
    const publication = handler.model.publishNotification(command.now_ns, command.input);

    try handler.effects.reschedule(handler.effects.context);
    return publication;
}
