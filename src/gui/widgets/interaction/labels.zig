const data = @import("model");
const Target = @import("Target.zig");
const client = @import("telar-client");

/// Borrows semantic names only until registry registration copies them.
/// Example: `const label = labels.forAction(&projection, action);`
pub fn forAction(projection: *const client.Projection, action: Target.Action) []const u8 {
    return switch (action) {
        .resize_sidebar => "Resize sidebar",
        .custom => "Agents",
        .text_field => |field| if (field == .name) "Name or query" else "Working directory",
        .change_review => "Review changes",
        .prompt => |prompt_action| if (prompt_action == .submit) "Create context" else "Cancel",
        .complete_path => "Choose folder",
        .history => |action_value| switch (action_value) {
            .select => "Select command",
            .submit => "Use selected command",
            .submit_alternate => "Use selected command the other way",
            .cycle_scope => "Change history scope",
            .select_scope => |scope| switch (scope) {
                .global => "Search all history",
                .workspace => "Search this workspace",
                .cwd => "Search this directory",
                .pane => "Search this pane",
            },
            .select_author => |author| switch (author) {
                .human => "Show your commands",
                .agent => "Show agent commands",
                .all => "Show everyone's commands",
            },
            .toggle_failed => "Show only failed commands",
            .toggle_inspection => "Inspect command",
            .page_older => "Older commands",
            .copy => "Copy command",
            .remove => "Delete command",
            .visit_pane => "Go to the command's pane",
        },
        .intent => |intent| switch (intent) {
            .toggle_sidebar => "Toggle sidebar",
            .toggle_workspace_list => "Toggle workspace list",
            .create_tab => "Create tab",
            .toggle_pane_fullscreen => "Leave fullscreen",
            .move_tab => "Move tab",
            .select_tab, .rename_tab => |id| blk: {
                if (projection.model.tabs.find(id)) |tab| {
                    break :blk data.tab_label.text(projection.model, tab);
                }

                break :blk "Tab";
            },
            .select_workspace => |id| blk: {
                if (projection.workspaces.indexOf(id)) |index| {
                    break :blk projection.workspaces.nameAt(index);
                }

                break :blk "Workspace";
            },
            .peek_agent => "Peek at agent",
            .focus_agent => |key| blk: {
                for (projection.agents.slice()) |*agent| {
                    if (!std.meta.eql(agent.key, key)) {
                        continue;
                    }

                    // A task card is known by its task, like the card shows it.
                    if (client.fleet_order.taskRow(projection.workspaces, agent)) |task| {
                        break :blk task.displayName();
                    }

                    break :blk agent.displayName();
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
