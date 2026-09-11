const ModelType = @import("../../model/Model.zig");
const TimerEffects = @import("TimerEffects.zig");
const NotificationChangeType = @import("../../model/NotificationChange.zig");
const AdvanceNotificationsHandler = @This();

model: *ModelType,
effects: TimerEffects,

/// Advances every transition before scheduling the next useful deadline.
///
/// ```zig
/// _ = try handler.execute(now_ns);
/// ```
pub fn execute(handler: *AdvanceNotificationsHandler, now_ns: u64) !?NotificationChangeType {
    const change = handler.model.advanceNotifications(now_ns);

    try handler.effects.reschedule(handler.effects.context);
    return change;
}
