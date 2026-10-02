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
        .preview => |preview| switch (preview) {
            .open => "Open image preview",
            .close => "Close image preview",
            .hold => "Image preview",
        },
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
            .machine_picker => "Switch machine",
            .select_machine => |slot| if (projection.machines) |machines| machines.label(slot) else "Machine",
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
            .focus_machine_agent => |target| blk: {
                for (projection.activity_sources) |source| {
                    if (source.slot == target.slot) {
                        const agent = target.resolve(source.model) orelse break :blk "Agent";
                        if (client.fleet_order.taskRow(&source.model.workspace_list_snapshot, agent)) |task| {
                            break :blk task.displayName();
                        }

                        break :blk agent.displayName();
                    }
                }

                break :blk "Agent";
            },
            .open_machine_worktree => "Open command workspace",
            .peek_agent, .peek_machine_agent => "Peek at agent",
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
            // The chip reads as the reason it shows; a press dismisses it.
            .diagnostic_dismiss => projection.diagnostic orelse "Dismiss diagnostic",
            .prompt_row => "Choose result",
            .bar_component => |component| blk: {
                const content = projection.bar_state.layout.content(component.position) orelse break :blk "Bar item";
                break :blk componentName(content, component.node) orelse "Bar item";
            },
            .panel_component => |index| componentName(&projection.bar_state.panel.content, index) orelse "Panel button",
            .toggle_bar_overflow => "More bar items",
            .close_panel => "Close panel",
            .none => "",
        },
    };
}

/// The words a screen reader says for a bar or panel component: its own
/// text, else its mark, else its first child's text.
fn componentName(content: anytype, index: u8) ?[]const u8 {
    if (index >= content.node_count) {
        return null;
    }

    const node = content.slice()[index];
    if (node.text.len != 0) {
        return content.text(node.text);
    }
    if (node.mark) |mark| {
        return @tagName(mark);
    }

    for (content.slice()) |child| {
        if (child.parent != index or child.in_tooltip or child.text.len == 0) {
            continue;
        }

        // A clock's text is its format, not what it says.
        return if (child.kind == .clock) "Clock" else content.text(child.text);
    }

    return null;
}

const std = @import("std");
