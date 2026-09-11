//! Application policy for one rejected client request.

const std = @import("std");
const core = @import("telar-core");
const notifications = @import("../../root.zig").notifications;
const client_requests = @import("../../connection/root.zig").requests;

pub const schema = core.schema;

pub const Command = @import("Command.zig");

pub const SplitRecovery = enum {
    current,
    stale,
};

pub const InitialOpenRecovery = enum {
    retried,
    unrecoverable,
};

pub const InitialOpenFailure = @import("InitialOpenFailure.zig");

pub const RecoveryEffects = @import("RecoveryEffects.zig");

pub const NotificationEffects = @import("NotificationEffects.zig");

pub const ReportingEffects = @import("ReportingEffects.zig");

pub const Outcome = enum {
    ignored,
    recovered,
    notified,
    fatal,
};

pub const HandleRequestFailureHandler = @import("HandleRequestFailureHandler.zig");

pub fn notification(command: Command) notifications.Input {
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

pub const EffectEvent = enum {
    split,
    attachment,
    close_tab,
    initial_open,
    publish,
    report,
};

const EffectsCapture = @import("RequestFailureEffectsCapture.zig");

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
