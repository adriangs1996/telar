const AdvanceNotificationsHandler = @This();
const client_model = @import("../../root.zig").model;
const TimerEffects = @import("TimerEffects.zig");
model: *client_model.Model,
effects: TimerEffects,

/// Advances every transition before scheduling the next useful deadline.
///
/// ```zig
/// _ = try handler.execute(now_ns);
/// ```
pub fn execute(handler: *AdvanceNotificationsHandler, now_ns: u64) !?client_model.NotificationChange {
    const change = handler.model.advanceNotifications(now_ns);

    try handler.effects.reschedule(handler.effects.context);
    return change;
}
