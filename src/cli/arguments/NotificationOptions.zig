const NotificationOptions = @This();
const core = @import("telar-core");
const std = @import("std");
const Cursor = @import("cursor_support.zig").Cursor;
title: [*:0]const u8,
body: ?[*:0]const u8 = null,
level: core.schema.NotificationLevel = .info,
duration_ms: u32 = core.schema.default_notification_duration_ms,
target: core.schema.NotificationTarget = .none,
socket: ?[*:0]const u8 = null,

pub fn parse(args: []const [*:0]const u8) !NotificationOptions {
    if (args.len < 2 or !std.mem.eql(u8, std.mem.span(args[0]), "show")) {
        return error.MissingNotificationShow;
    }

    var options: NotificationOptions = .{ .title = args[1] };
    if (std.mem.span(options.title).len == 0) {
        return error.EmptyNotificationTitle;
    }

    var target_set = false;
    var level_set = false;
    var duration_set = false;
    const index: usize = 2;
    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--body")) {
            if (options.body != null) {
                return error.DuplicateNotificationBody;
            }
            const value = try cursor.require(error.MissingNotificationBody);

            options.body = value;
        } else if (std.mem.eql(u8, arg, "--level")) {
            if (level_set) {
                return error.DuplicateNotificationLevel;
            }
            const value = try cursor.require(error.MissingNotificationLevel);

            const level = std.mem.span(value);
            options.level = if (std.mem.eql(u8, level, "info"))
                .info
            else if (std.mem.eql(u8, level, "success"))
                .success
            else if (std.mem.eql(u8, level, "warning"))
                .warning
            else if (std.mem.eql(u8, level, "failure"))
                .failure
            else
                return error.InvalidNotificationLevel;
            level_set = true;
        } else if (std.mem.eql(u8, arg, "--duration")) {
            if (duration_set) {
                return error.DuplicateNotificationDuration;
            }
            const value = try cursor.require(error.MissingNotificationDuration);

            options.duration_ms = try std.fmt.parseUnsigned(
                u32,
                std.mem.span(value),
                10,
            );
            if (options.duration_ms < core.schema.min_notification_duration_ms or
                options.duration_ms > core.schema.max_notification_duration_ms)
            {
                return error.InvalidNotificationDuration;
            }

            duration_set = true;
        } else if (std.mem.eql(u8, arg, "--pane")) {
            if (target_set) {
                return error.ConflictingNotificationTargets;
            }
            const value = try cursor.require(error.MissingPaneId);

            options.target = .{ .pane = try core.schema.id.pane(try std.fmt.parseUnsigned(
                u64,
                std.mem.span(value),
                10,
            )) };
            target_set = true;
        } else if (std.mem.eql(u8, arg, "--tab")) {
            if (target_set) {
                return error.ConflictingNotificationTargets;
            }
            const value = try cursor.require(error.MissingTabId);

            options.target = .{ .tab = try core.schema.id.tab(try std.fmt.parseUnsigned(
                u64,
                std.mem.span(value),
                10,
            )) };
            target_set = true;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            if (target_set) {
                return error.ConflictingNotificationTargets;
            }
            const value = try cursor.require(error.MissingWorkspaceId);

            options.target = .{ .workspace = try core.schema.id.workspace(try std.fmt.parseUnsigned(
                u64,
                std.mem.span(value),
                10,
            )) };
            target_set = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            if (options.socket != null) {
                return error.DuplicateSocketOption;
            }
            const value = try cursor.require(error.MissingSocketPath);

            options.socket = value;
        } else {
            return error.UnknownNotificationOption;
        }
    }
    return options;
}
