const EffectsCapture = @This();
const source_namespace = @import("request_failure.zig");
const notifications = @import("../../root.zig").notifications;
const RecoveryEffects = @import("RecoveryEffects.zig");
const NotificationEffects = @import("NotificationEffects.zig");
const ReportingEffects = @import("ReportingEffects.zig");
const HandleRequestFailureHandler = @import("HandleRequestFailureHandler.zig");
const client_requests = @import("../../connection/root.zig").requests;
const InitialOpenFailure = @import("InitialOpenFailure.zig");
events: [3]source_namespace.EffectEvent = undefined,
event_count: usize = 0,
split_recovery: source_namespace.SplitRecovery = .current,
initial_open_recovery: source_namespace.InitialOpenRecovery = .retried,
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

pub fn handler(capture: *EffectsCapture) HandleRequestFailureHandler {
    return .{
        .recovery = capture.recoveryPort(),
        .notifications = capture.notificationPort(),
        .reporting = capture.reportingPort(),
    };
}

fn record(capture: *EffectsCapture, event: source_namespace.EffectEvent) !void {
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

fn recoverSplit(context: *anyopaque, split: client_requests.Split) !source_namespace.SplitRecovery {
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

fn recoverCloseTab(context: *anyopaque, location: source_namespace.schema.TabLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = location;
    try capture.record(.close_tab);
}

fn recoverInitialOpen(context: *anyopaque, failure: InitialOpenFailure) !source_namespace.InitialOpenRecovery {
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

pub fn reset(capture: *EffectsCapture) void {
    capture.event_count = 0;
    capture.notification = null;
    capture.reported_message = null;
}
