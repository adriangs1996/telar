//! Application policy for one rejected client request.

const core = @import("telar-core");
const Command = @import("Command.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const std = @import("std");
const client_requests = @import("../../connection/requests.zig");
const notifications = @import("../../notifications/notifications.zig");

pub const Outcome = @import("../../types/RequestFailureOutcome.zig").RequestFailureOutcome;

pub fn notification(command: Command) InputType {
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
        .change_review_query => "Could not load change review",
        .change_review_command => "Could not update change review",
        .agent_prompt => "Could not send prompt",
        .agent_control => "Could not update agent",
        .agent_query => "Could not load conversation",
        .agent_history => "Could not load earlier messages",
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
    };
}

fn notificationTarget(continuation: client_requests.Continuation) notifications.Target {
    return switch (continuation) {
        .agent_history => |operation| .{
            .focus_pane = operation.owner.pane_id,
        },
        .change_review_query, .change_review_command => |operation| .{
            .focus_pane = operation.pane_id,
        },
        .editor_open, .agent_prompt, .agent_control, .agent_query => |operation| .{
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
