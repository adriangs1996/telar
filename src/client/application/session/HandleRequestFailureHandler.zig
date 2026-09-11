const HandleRequestFailureHandler = @This();
const RecoveryEffects = @import("RecoveryEffects.zig");
const NotificationEffects = @import("NotificationEffects.zig");
const ReportingEffects = @import("ReportingEffects.zig");
const Command = @import("Command.zig");
const source_namespace = @import("request_failure.zig");
recovery: RecoveryEffects,
notifications: NotificationEffects,
reporting: ReportingEffects,

/// Applies recovery policy before publishing any user-visible failure.
/// Fatal outcomes and processing errors report the runtime message once.
///
/// ```zig
/// const outcome = try handler.execute(command);
/// ```
pub fn execute(handler: *HandleRequestFailureHandler, command: Command) !source_namespace.Outcome {
    const outcome = handler.apply(command) catch |err| {
        handler.reporting.report(handler.reporting.context, command.message);

        return err;
    };
    if (outcome == .fatal) {
        handler.reporting.report(handler.reporting.context, command.message);
    }

    return outcome;
}

fn apply(handler: *HandleRequestFailureHandler, command: Command) !source_namespace.Outcome {
    switch (command.continuation) {
        .ignored => return .ignored,
        .workspace_snapshot, .tab_snapshot => return .fatal,
        .initial_open => |open| {
            const recovery = try handler.recovery.initial_open(handler.recovery.context, .{
                .open = open,
                .code = command.code,
            });

            return switch (recovery) {
                .retried => .recovered,
                .unrecoverable => .fatal,
            };
        },
        .split => |split| {
            const recovery = try handler.recovery.split(handler.recovery.context, split);
            if (recovery == .stale) {
                return .ignored;
            }
        },
        .attach_pane => |attachment| {
            if (command.code == .pane_not_found) {
                try handler.recovery.attachment(handler.recovery.context, attachment);
            }
        },
        .close_tab => |location| {
            try handler.recovery.close_tab(handler.recovery.context, location);
        },
        .close_pane,
        .create_workspace,
        .rename_workspace,
        .create_tab,
        .rename_tab,
        .move_tab,
        .notification,
        => {},
    }

    try handler.notifications.publish(handler.notifications.context, source_namespace.notification(command));
    return .notified;
}
