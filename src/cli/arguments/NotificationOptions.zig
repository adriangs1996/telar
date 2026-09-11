const NotificationLevelType = @import("telar-core").NotificationLevel;
const default_notification_duration_ms_module = @import("telar-core").default_notification_duration_ms;
const NotificationTargetType = @import("telar-core").NotificationTarget;
const std = @import("std");
const Cursor = @import("Cursor.zig");
const min_notification_duration_ms_module = @import("telar-core").min_notification_duration_ms;
const max_notification_duration_ms_module = @import("telar-core").max_notification_duration_ms;
const pane_module = @import("telar-core").pane;
const tab_module = @import("telar-core").tab;
const workspace_module = @import("telar-core").workspace;
const NotificationOptions = @This();

title: [*:0]const u8,
body: ?[*:0]const u8 = null,
level: NotificationLevelType = .info,
duration_ms: u32 = default_notification_duration_ms_module,
target: NotificationTargetType = .none,
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
            if (options.duration_ms < min_notification_duration_ms_module or
                options.duration_ms > max_notification_duration_ms_module)
            {
                return error.InvalidNotificationDuration;
            }

            duration_set = true;
        } else if (std.mem.eql(u8, arg, "--pane")) {
            if (target_set) {
                return error.ConflictingNotificationTargets;
            }
            const value = try cursor.require(error.MissingPaneId);

            options.target = .{ .pane = try pane_module(try std.fmt.parseUnsigned(
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

            options.target = .{ .tab = try tab_module(try std.fmt.parseUnsigned(
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

            options.target = .{ .workspace = try workspace_module(try std.fmt.parseUnsigned(
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
