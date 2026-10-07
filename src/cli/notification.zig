//! The `telar notification show` command.

const client = @import("telar-client");
const localsocket = @import("localsocket");
const core = @import("telar-core");
const std = @import("std");
const NotificationOptions = @import("arguments/NotificationOptions.zig");
const limit_reached = @import("limit_reached.zig");
const RuntimeConnector = client.RuntimeConnector;

const request_id: core.RequestId = @enumFromInt(1);
const request_buffer_size = 1 + 8 + 1 + 4 + 1 + 8 + 2 + core.max_notification_title_bytes + 2 + core.max_notification_message_bytes + 2 + core.max_notification_link_bytes;

/// Sends one bounded notification request to the running local runtime and
/// fails when no UI client accepted it. A title or body past its limit is
/// cut on a UTF-8 boundary and still shown; the command then prints the
/// limit notice and fails, and the runtime shows it too.
///
/// ```zig
/// try notification.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: NotificationOptions) !void {
    var message = request(options);
    const reach = fitText(&message.notification);
    send(init, message.notification, options.socket, reach) catch |err| {
        switch (err) {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            error.RuntimeNotRunning => std.debug.print("telar notification: runtime is not running\n", .{}),
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            error.NoNotificationClients => std.debug.print("telar notification: no UI client is connected\n", .{}),
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            else => std.debug.print("telar notification: {s}\n", .{@errorName(err)}),
        }

        return err;
    };

    if (reach) |cut| {
        limit_reached.report(cut);
        return error.NotificationTextTooLong;
    }
}

/// Cuts a title and body past their limits and returns the reach of the
/// body when it was cut, else of the title; null when both fit.
fn fitText(notification: *core.Notification) ?core.LimitReach {
    var reach: ?core.LimitReach = null;
    if (notification.title.len > core.max_notification_title_bytes) {
        reach = .{
            .limit = core.notification_title_limit,
            .requested = notification.title.len,
        };
        notification.title = core.utf8Prefix(notification.title, core.max_notification_title_bytes);
    }

    if (notification.message.len > core.max_notification_message_bytes) {
        reach = .{
            .limit = core.notification_message_limit,
            .requested = notification.message.len,
        };
        notification.message = core.utf8Prefix(notification.message, core.max_notification_message_bytes);
    }

    return reach;
}

/// Shows one notification in every UI client of the local runtime, or
/// fails with `error.NoNotificationClients` when none took it. It never
/// starts a runtime.
///
/// ```zig
/// try notification.send(process_init, .{ .title = "Log in to Codex on box", .link = url }, null, null);
/// ```
///
/// A `truncated` reach is reported on the same connection once a window
/// took the notification, so the runtime shows the limit notice too.
pub fn send(init: std.process.Init, notification: core.Notification, socket: ?[*:0]const u8, truncated: ?core.LimitReach) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, socket);
    var connection = connector.connect() catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => return error.RuntimeNotRunning,
        else => |other| return other,
    };
    defer connection.deinit(init.io);

    var send_buffer: [request_buffer_size]u8 = undefined;
    try connection.send(init.io, try core.encodeShowNotification(&send_buffer, .{
        .request_id = request_id,
        .notification = notification,
    }));

    const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.decodeServer(try connection.receive(init.io, receive_buffer));
    switch (response) {
        .notification_shown => |shown| {
            try validateAcknowledgement(shown);
            const reach = truncated orelse return;
            var report_buffer: [core.max_report_limit_bytes]u8 = undefined;
            const report = core.encodeReportLimit(&report_buffer, .{
                .reach = reach,
                .hits = 1,
            }) catch return;
            // The notification was already acknowledged; reporting its limit is a secondary observation.
            connection.send(init.io, report) catch {};
        },
        .request_failed => |failure| {
            // This is the command failure diagnostic on stderr; keep its CLI prefix and leave stdout available for results.
            std.debug.print("telar notification: {s}\n", .{failure.message});
            return error.NotificationFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn request(options: NotificationOptions) core.ShowNotification {
    return .{
        .request_id = request_id,
        .notification = .{
            .level = options.level,
            .duration_ms = options.duration_ms,
            .target = options.target,
            .title = std.mem.span(options.title),
            .message = if (options.body) |body| std.mem.span(body) else "",
            .link = if (options.link) |link| std.mem.span(link) else "",
        },
    };
}

fn validateAcknowledgement(shown: core.NotificationShown) !void {
    if (shown.request_id != request_id) {
        return error.UnexpectedRuntimeResponse;
    }

    if (shown.delivered_clients == 0) {
        return error.NoNotificationClients;
    }
}
