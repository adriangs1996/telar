//! Application policy for one rejected client request.

const std = @import("std");
const core = @import("telar-core");
const notifications = @import("../../notifications/root.zig");
const client_requests = @import("../requests.zig");

const schema = core.schema;

pub const Command = struct {
    continuation: client_requests.Continuation,
    code: schema.FailureCode,
    /// Borrowed only for the synchronous notification publication.
    message: []const u8,
};

pub const SplitRecovery = enum {
    current,
    stale,
};

pub const InitialOpenRecovery = enum {
    retried,
    unrecoverable,
};

pub const InitialOpenFailure = struct {
    open: client_requests.InitialOpen,
    code: schema.FailureCode,
};

pub const RecoveryEffects = struct {
    context: *anyopaque,
    split: *const fn (*anyopaque, client_requests.Split) anyerror!SplitRecovery,
    attachment: *const fn (*anyopaque, client_requests.PaneOperation) anyerror!void,
    close_tab: *const fn (*anyopaque, schema.TabLocation) anyerror!void,
    initial_open: *const fn (*anyopaque, InitialOpenFailure) anyerror!InitialOpenRecovery,
};

pub const NotificationEffects = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, notifications.Input) anyerror!void,
};

pub const ReportingEffects = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, []const u8) void,
};

pub const Outcome = enum {
    ignored,
    recovered,
    notified,
    fatal,
};

pub const HandleRequestFailureHandler = struct {
    recovery: RecoveryEffects,
    notifications: NotificationEffects,
    reporting: ReportingEffects,

    /// Applies recovery policy before publishing any user-visible failure.
    /// Fatal outcomes and processing errors report the runtime message once.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *HandleRequestFailureHandler, command: Command) !Outcome {
        const outcome = handler.apply(command) catch |err| {
            handler.reporting.report(handler.reporting.context, command.message);

            return err;
        };
        if (outcome == .fatal) {
            handler.reporting.report(handler.reporting.context, command.message);
        }

        return outcome;
    }

    fn apply(handler: *HandleRequestFailureHandler, command: Command) !Outcome {
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

        try handler.notifications.publish(handler.notifications.context, notification(command));
        return .notified;
    }
};

fn notification(command: Command) notifications.Input {
    return .{
        .level = .failure,
        .title = failureTitle(command.continuation),
        .message = command.message,
        .target = notificationTarget(command.continuation),
        .duration_ns = 7 * std.time.ns_per_s,
    };
}

fn failureTitle(continuation: client_requests.Continuation) []const u8 {
    return switch (continuation) {
        .split => "Could not split pane",
        .close_pane => "Could not close pane",
        .attach_pane => "Could not attach pane",
        .create_workspace => "Could not create workspace",
        .rename_workspace => "Could not rename workspace",
        .create_tab => "Could not create tab",
        .rename_tab => "Could not rename tab",
        .close_tab => "Could not close tab",
        .move_tab => "Could not move tab",
        .notification => "Could not show notification",
        .initial_open, .workspace_snapshot, .tab_snapshot => "Runtime request failed",
        .ignored => "Request ignored",
    };
}

fn notificationTarget(continuation: client_requests.Continuation) notifications.Target {
    return switch (continuation) {
        .split => |split| .{ .focus_pane = split.target_pane },
        .close_pane, .attach_pane => |operation| .{ .select_tab = operation.location.tab_id },
        .tab_snapshot, .rename_tab, .close_tab, .move_tab => |location| .{
            .select_tab = location.tab_id,
        },
        .rename_workspace, .workspace_snapshot => |location| workspaceNotificationTarget(location),
        .create_tab => |creation| workspaceNotificationTarget(creation.workspace),
        .initial_open, .create_workspace, .notification, .ignored => .none,
    };
}

fn workspaceNotificationTarget(location: schema.WorkspaceLocation) notifications.Target {
    return switch (location) {
        .workspace => |workspace| .{ .select_workspace = workspace },
        .worktree => .none,
    };
}

const EffectEvent = enum {
    split,
    attachment,
    close_tab,
    initial_open,
    publish,
    report,
};

const EffectsCapture = struct {
    events: [3]EffectEvent = undefined,
    event_count: usize = 0,
    split_recovery: SplitRecovery = .current,
    initial_open_recovery: InitialOpenRecovery = .retried,
    notification: ?notifications.Input = null,
    reported_message: ?[]const u8 = null,
    fail_recovery: bool = false,
    fail_notification: bool = false,

    fn recoveryPort(capture: *EffectsCapture) RecoveryEffects {
        return .{
            .context = capture,
            .split = recoverSplit,
            .attachment = recoverAttachment,
            .close_tab = recoverCloseTab,
            .initial_open = recoverInitialOpen,
        };
    }

    fn notificationPort(capture: *EffectsCapture) NotificationEffects {
        return .{ .context = capture, .publish = publish };
    }

    fn reportingPort(capture: *EffectsCapture) ReportingEffects {
        return .{ .context = capture, .report = report };
    }

    fn handler(capture: *EffectsCapture) HandleRequestFailureHandler {
        return .{
            .recovery = capture.recoveryPort(),
            .notifications = capture.notificationPort(),
            .reporting = capture.reportingPort(),
        };
    }

    fn record(capture: *EffectsCapture, event: EffectEvent) !void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;

        switch (event) {
            .split, .attachment, .close_tab, .initial_open => if (capture.fail_recovery) {
                return error.RecoveryFailed;
            },
            .publish => if (capture.fail_notification) {
                return error.NotificationFailed;
            },
            .report => {},
        }
    }

    fn recoverSplit(context: *anyopaque, split: client_requests.Split) !SplitRecovery {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = split;
        try capture.record(.split);

        return capture.split_recovery;
    }

    fn recoverAttachment(context: *anyopaque, attachment: client_requests.PaneOperation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = attachment;
        try capture.record(.attachment);
    }

    fn recoverCloseTab(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = location;
        try capture.record(.close_tab);
    }

    fn recoverInitialOpen(context: *anyopaque, failure: InitialOpenFailure) !InitialOpenRecovery {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        _ = failure;
        try capture.record(.initial_open);

        return capture.initial_open_recovery;
    }

    fn publish(context: *anyopaque, input: notifications.Input) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.notification = input;
        try capture.record(.publish);
    }

    fn report(context: *anyopaque, message: []const u8) void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.reported_message = message;
        capture.record(.report) catch unreachable;
    }

    fn reset(capture: *EffectsCapture) void {
        capture.event_count = 0;
        capture.notification = null;
        capture.reported_message = null;
    }
};

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(2),
};

fn testingCommand(continuation: client_requests.Continuation) Command {
    return .{
        .continuation = continuation,
        .code = .internal,
        .message = "runtime rejected request",
    };
}

test "request failure ignores retired work and classifies snapshot loss as fatal" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(.ignored)));
    try std.testing.expectEqual(
        Outcome.fatal,
        try handler.execute(testingCommand(.{ .workspace_snapshot = testing_location.workspace })),
    );
    try std.testing.expectEqual(
        Outcome.fatal,
        try handler.execute(testingCommand(.{ .tab_snapshot = testing_location })),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .report, .report },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualStrings("runtime rejected request", capture.reported_message.?);
}

test "request failure retries a vanished remembered pane once" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();
    var command = testingCommand(.{ .initial_open = .{ .fallback_workspace = @enumFromInt(7) } });
    command.code = .pane_not_found;

    try std.testing.expectEqual(Outcome.recovered, try handler.execute(command));
    try std.testing.expectEqualSlices(EffectEvent, &.{.initial_open}, capture.events[0..capture.event_count]);
    try std.testing.expect(capture.notification == null);
    try std.testing.expect(capture.reported_message == null);

    capture.reset();
    capture.initial_open_recovery = .unrecoverable;
    command.code = .internal;

    try std.testing.expectEqual(Outcome.fatal, try handler.execute(command));
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .initial_open, .report },
        capture.events[0..capture.event_count],
    );
    try std.testing.expect(capture.notification == null);
    try std.testing.expectEqualStrings("runtime rejected request", capture.reported_message.?);
}

test "request failure suppresses a stale split after recovery" {
    const continuation: client_requests.Continuation = .{ .split = .{
        .target_pane = @enumFromInt(3),
        .location = testing_location,
        .axis = .horizontal,
        .area = .{ .w = 40, .h = 10 },
    } };
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(Outcome.notified, try handler.execute(testingCommand(continuation)));
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .split, .publish },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualStrings("Could not split pane", capture.notification.?.title);
    try std.testing.expectEqualDeep(
        notifications.Target{ .focus_pane = @enumFromInt(3) },
        capture.notification.?.target,
    );

    capture.reset();
    capture.split_recovery = .stale;

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(continuation)));
    try std.testing.expectEqualSlices(EffectEvent, &.{.split}, capture.events[0..capture.event_count]);
    try std.testing.expect(capture.notification == null);
}

test "request failure refreshes only a missing pane attachment" {
    const continuation: client_requests.Continuation = .{ .attach_pane = .{
        .pane_id = @enumFromInt(3),
        .location = testing_location,
    } };
    var capture: EffectsCapture = .{};
    var handler = capture.handler();
    var command = testingCommand(continuation);

    try std.testing.expectEqual(Outcome.notified, try handler.execute(command));
    try std.testing.expectEqualSlices(EffectEvent, &.{.publish}, capture.events[0..capture.event_count]);

    capture.reset();
    command.code = .pane_not_found;

    try std.testing.expectEqual(Outcome.notified, try handler.execute(command));
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .attachment, .publish },
        capture.events[0..capture.event_count],
    );
}

test "request failure restores a rejected tab close before notifying" {
    var capture: EffectsCapture = .{};
    var handler = capture.handler();

    try std.testing.expectEqual(
        Outcome.notified,
        try handler.execute(testingCommand(.{ .close_tab = testing_location })),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .close_tab, .publish },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualStrings("Could not close tab", capture.notification.?.title);
    try std.testing.expectEqualDeep(
        notifications.Target{ .select_tab = testing_location.tab_id },
        capture.notification.?.target,
    );
}

test "request failure maps direct notification titles and targets" {
    const cases = [_]struct {
        continuation: client_requests.Continuation,
        title: []const u8,
        target: notifications.Target,
    }{
        .{
            .continuation = .{ .close_pane = .{ .pane_id = @enumFromInt(3), .location = testing_location } },
            .title = "Could not close pane",
            .target = .{ .select_tab = testing_location.tab_id },
        },
        .{
            .continuation = .{ .create_workspace = .{ .cols = 80, .rows = 24 } },
            .title = "Could not create workspace",
            .target = .none,
        },
        .{
            .continuation = .{ .rename_workspace = testing_location.workspace },
            .title = "Could not rename workspace",
            .target = .{ .select_workspace = @enumFromInt(1) },
        },
        .{
            .continuation = .{ .create_tab = .{
                .workspace = testing_location.workspace,
                .size = .{ .cols = 80, .rows = 24 },
            } },
            .title = "Could not create tab",
            .target = .{ .select_workspace = @enumFromInt(1) },
        },
        .{
            .continuation = .{ .rename_tab = testing_location },
            .title = "Could not rename tab",
            .target = .{ .select_tab = testing_location.tab_id },
        },
        .{
            .continuation = .{ .move_tab = testing_location },
            .title = "Could not move tab",
            .target = .{ .select_tab = testing_location.tab_id },
        },
        .{
            .continuation = .notification,
            .title = "Could not show notification",
            .target = .none,
        },
    };

    for (cases) |case| {
        var capture: EffectsCapture = .{};
        var handler = capture.handler();

        try std.testing.expectEqual(Outcome.notified, try handler.execute(testingCommand(case.continuation)));
        try std.testing.expectEqualSlices(EffectEvent, &.{.publish}, capture.events[0..capture.event_count]);
        try std.testing.expectEqualStrings(case.title, capture.notification.?.title);
        try std.testing.expectEqualStrings("runtime rejected request", capture.notification.?.message);
        try std.testing.expectEqualDeep(case.target, capture.notification.?.target);
        try std.testing.expectEqual(@as(u64, 7 * std.time.ns_per_s), capture.notification.?.duration_ns);
    }
}

test "request failure does not notify after recovery failure" {
    var capture: EffectsCapture = .{ .fail_recovery = true };
    var handler = capture.handler();

    try std.testing.expectError(
        error.RecoveryFailed,
        handler.execute(testingCommand(.{ .close_tab = testing_location })),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .close_tab, .report },
        capture.events[0..capture.event_count],
    );
    try std.testing.expect(capture.notification == null);
    try std.testing.expectEqualStrings("runtime rejected request", capture.reported_message.?);
}

test "request failure retains recovery when notification publication fails" {
    var capture: EffectsCapture = .{ .fail_notification = true };
    var handler = capture.handler();

    try std.testing.expectError(
        error.NotificationFailed,
        handler.execute(testingCommand(.{ .close_tab = testing_location })),
    );
    try std.testing.expectEqualSlices(
        EffectEvent,
        &.{ .close_tab, .publish, .report },
        capture.events[0..capture.event_count],
    );
    try std.testing.expectEqualStrings("runtime rejected request", capture.reported_message.?);
}
