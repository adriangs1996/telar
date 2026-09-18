const client = @import("telar-client");
const Action = @import("Target.zig").Action;

/// Borrows semantic names only until registry registration copies them.
/// Example: `const label = labels.forAction(&projection, action);`
pub fn forAction(projection: *const client.Projection, action: Action) []const u8 {
    return switch (action) {
        .resize_sidebar => "Resize sidebar",
        .custom => "Agents",
        .text_field => |field| if (field == .name) "Name or query" else "Working directory",
        .composer => "Message to agent",
        .transcript => "Conversation",
        .message_link => "Link",
        .thread_item => |control| if (control.operation == .copy) "Copy message" else "Show activity details",
        .composer_selector => |selector| switch (selector.kind) {
            .model => "Choose model",
            .effort => "Choose reasoning effort",
            .access => "Choose permissions",
            .recent => "Resume conversation",
        },
        .composer_choice => "Choose option",
        .composer_completion => "Complete command or skill",
        .agent_control => |control| switch (control.kind) {
            .submit => "Send message",
            .interrupt => "Stop agent",
            .approve => "Approve",
            .decline => "Decline",
            .review => "Review full request",
            .remove_image => "Remove image",
            .preview_image => "Preview image",
            .close_image => "Close image preview",
        },
        .prompt => |prompt_action| if (prompt_action == .submit) "Create context" else "Cancel",
        .complete_path => "Choose folder",
        .history => |action_value| switch (action_value) {
            .select => "Select command",
            .submit => "Use selected command",
            .cycle_scope => "Change history scope",
            .toggle_inspection => "Inspect command",
        },
        .intent => |intent| switch (intent) {
            .toggle_sidebar => "Toggle sidebar",
            .toggle_workspace_list => "Toggle workspace list",
            .create_tab => "Create tab",
            .move_tab => "Move tab",
            .select_tab, .rename_tab => |id| blk: {
                for (projection.tabs.items[0..projection.tabs.count]) |*slot| {
                    if (slot.*) |*tab| {
                        if (tab.location.tab_id == id) {
                            break :blk tab.labelSlice();
                        }
                    }
                }

                break :blk "Tab";
            },
            .select_workspace => |id| blk: {
                if (projection.workspaces.indexOf(id)) |index| {
                    break :blk projection.workspaces.nameAt(index);
                }

                break :blk "Workspace";
            },
            .focus_agent => |key| blk: {
                for (projection.agents.slice()) |*agent| {
                    if (std.meta.eql(agent.key, key)) {
                        break :blk agent.displayName();
                    }
                }

                break :blk "Agent";
            },
            .focus_pane => "Terminal pane",
            .resize_sidebar => "Resize sidebar",
            .notification_activate => "Open notification",
            .notification_dismiss => "Dismiss notification",
            .attachment_dismiss => "Dismiss attachment",
            .prompt_row => "Choose result",
            .none => "",
        },
    };
}

const std = @import("std");
