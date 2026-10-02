//! Application policy for one rejected client request.

const core = @import("telar-core");
const Command = @import("Command.zig");
const NotificationInput = @import("../notifications/NotificationInput.zig");
const std = @import("std");
const client_requests = @import("requests.zig");
const notifications = @import("../notifications/notifications.zig");

pub fn notification(command: Command) NotificationInput {
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
        .editor_open => "Could not open file",
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
        .peek_screen => "Could not read the agent's pane",
        .peek_action => "The agent did not take it",
    };
}

fn notificationTarget(continuation: client_requests.Continuation) notifications.Target {
    return switch (continuation) {
        .editor_open => |operation| .{
            .focus_pane = operation.pane_id,
        },
        .split => |split| .{
            .focus_pane = split.target_pane,
        },
        .close_pane, .attach_pane => |operation| .{
            .select_tab = operation.location.tab_id,
        },
        .tab_snapshot, .rename_tab, .close_tab, .move_tab => |location| .{
            .select_tab = location.tab_id,
        },
        .rename_workspace, .workspace_snapshot => |location| workspaceNotificationTarget(location),
        .create_tab => |creation| workspaceNotificationTarget(creation.workspace),
        .peek_screen, .peek_action => |pane_id| .{
            .focus_pane = pane_id,
        },
        .initial_open, .create_workspace, .notification, .ignored => .none,
    };
}

fn workspaceNotificationTarget(location: core.WorkspaceLocation) notifications.Target {
    return switch (location) {
        .workspace => |workspace| .{
            .select_workspace = workspace,
        },
        .worktree => .none,
    };
}

const testing_location: core.TabLocation = .{
    .workspace = .{
        .workspace = @enumFromInt(1),
    },
    .tab_id = @enumFromInt(2),
};

fn testingCommand(continuation: client_requests.Continuation) Command {
    return .{
        .continuation = continuation,
        .code = .internal,
        .message = "runtime rejected request",
    };
}

test "request failure maps direct notification titles and targets" {
    const cases = [_]struct {
        continuation: client_requests.Continuation,
        title: []const u8,
        target: notifications.Target,
    }{
        .{
            .continuation = .{
                .close_pane = .{
                    .pane_id = @enumFromInt(3),
                    .location = testing_location,
                },
            },
            .title = "Could not close pane",
            .target = .{
                .select_tab = testing_location.tab_id,
            },
        },
        .{
            .continuation = .{
                .create_workspace = .{
                    .cols = 80,
                    .rows = 24,
                },
            },
            .title = "Could not create workspace",
            .target = .none,
        },
        .{
            .continuation = .{
                .rename_workspace = testing_location.workspace,
            },
            .title = "Could not rename workspace",
            .target = .{
                .select_workspace = @enumFromInt(1),
            },
        },
        .{
            .continuation = .{
                .create_tab = .{
                    .workspace = testing_location.workspace,
                    .size = .{
                        .cols = 80,
                        .rows = 24,
                    },
                },
            },
            .title = "Could not create tab",
            .target = .{
                .select_workspace = @enumFromInt(1),
            },
        },
        .{
            .continuation = .{
                .rename_tab = testing_location,
            },
            .title = "Could not rename tab",
            .target = .{
                .select_tab = testing_location.tab_id,
            },
        },
        .{
            .continuation = .{
                .move_tab = testing_location,
            },
            .title = "Could not move tab",
            .target = .{
                .select_tab = testing_location.tab_id,
            },
        },
        .{
            .continuation = .notification,
            .title = "Could not show notification",
            .target = .none,
        },
    };

    for (cases) |case| {
        const input = notification(testingCommand(case.continuation));
        try std.testing.expectEqualStrings(case.title, input.title);
        try std.testing.expectEqualStrings("runtime rejected request", input.message);
        try std.testing.expectEqualDeep(case.target, input.target);
        try std.testing.expectEqual(@as(u64, 7 * std.time.ns_per_s), input.duration_ns);
    }
}
