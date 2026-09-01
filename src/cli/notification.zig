//! The `telar notification show` command.

const std = @import("std");
const core = @import("telar-core");
const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

const NotificationOptions = parser.NotificationOptions;
const RuntimeConnector = runtime_connection.RuntimeConnector;
const request_id: core.schema.RequestId = @enumFromInt(1);
const request_buffer_size = 1 + 8 + 1 + 4 + 1 + 8 + 2 + core.schema.max_notification_title_bytes + 2 + core.schema.max_notification_message_bytes;

/// Sends one bounded notification request to the running local runtime and
/// fails when no UI client accepted it.
///
/// ```zig
/// try notification.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: NotificationOptions) !void {
    const connector = try RuntimeConnector.init(init, options.socket);
    var connection = connector.connect() catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            std.debug.print("telar notification: runtime is not running\n", .{});
            return error.RuntimeNotRunning;
        },
        else => |other| return other,
    };
    defer connection.deinit(init.io);

    var send_buffer: [request_buffer_size]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeShowNotification(&send_buffer, request(options)));

    const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.schema.decodeServer(try connection.receive(init.io, receive_buffer));
    switch (response) {
        .notification_shown => |shown| validateAcknowledgement(shown) catch |err| {
            if (err == error.NoNotificationClients) {
                std.debug.print("telar notification: no UI client is connected\n", .{});
            }

            return err;
        },
        .request_failed => |failure| {
            std.debug.print("telar notification: {s}\n", .{failure.message});
            return error.NotificationFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn request(options: NotificationOptions) core.schema.ShowNotification {
    return .{
        .request_id = request_id,
        .notification = .{
            .level = options.level,
            .duration_ms = options.duration_ms,
            .target = options.target,
            .title = std.mem.span(options.title),
            .message = if (options.body) |body| std.mem.span(body) else "",
        },
    };
}

fn validateAcknowledgement(shown: core.schema.NotificationShown) !void {
    if (shown.request_id != request_id) {
        return error.UnexpectedRuntimeResponse;
    }

    if (shown.delivered_clients == 0) {
        return error.NoNotificationClients;
    }
}

test "notification options map to one protocol request" {
    const message = request(.{
        .title = "Build complete",
        .body = "Open the pane",
        .level = .success,
        .duration_ms = 2500,
        .target = .{ .pane = @enumFromInt(42) },
    });

    try std.testing.expectEqual(request_id, message.request_id);
    try std.testing.expectEqual(core.schema.NotificationLevel.success, message.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), message.notification.duration_ms);
    try std.testing.expectEqual(@as(core.schema.PaneId, @enumFromInt(42)), message.notification.target.pane);
    try std.testing.expectEqualStrings("Build complete", message.notification.title);
    try std.testing.expectEqualStrings("Open the pane", message.notification.message);
}

test "notification requests use an empty body when none was provided" {
    const message = request(.{ .title = "Ready" });

    try std.testing.expectEqualStrings("", message.notification.message);
}

test "notification acknowledgement belongs to the request and reaches a client" {
    try validateAcknowledgement(.{ .request_id = request_id, .delivered_clients = 2 });
    try std.testing.expectError(error.NoNotificationClients, validateAcknowledgement(.{
        .request_id = request_id,
        .delivered_clients = 0,
    }));
    try std.testing.expectError(error.UnexpectedRuntimeResponse, validateAcknowledgement(.{
        .request_id = @enumFromInt(2),
        .delivered_clients = 1,
    }));
}
