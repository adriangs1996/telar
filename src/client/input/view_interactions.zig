//! Wires semantic view interactions to existing client use cases.

const data = @import("model");
const view_interaction = @import("view_interaction.zig");
const Client = @import("../execution/Client.zig");
const ViewInteractionCommand = @import("ViewInteractionCommand.zig");
const ViewInteractionOutcome = @import("ViewInteractionOutcome.zig");
const IntentOutcome = @import("IntentOutcome.zig");
const agent_attachments = @import("../attachments/agent_attachments.zig");
const agent_peek = @import("../agents/agent_peek.zig");
const bar_components = @import("bar_components.zig");
const bar_updates = @import("../config/bar_updates.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const name_prompt = @import("name_prompt.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const sidebar_toggle = @import("../workspace/sidebar_toggle.zig");
const tab_creation = @import("../workspace/tab_creation.zig");
const tab_move = @import("../workspace/tab_move.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");

/// Applies one interaction emitted by the view and returns its pane-input
/// routing decision.
///
/// ```zig
/// const outcome = try apply(client, tab, interaction);
/// ```
pub fn apply(client: *Client, tab: usize, interaction: ViewInteractionCommand) !ViewInteractionOutcome {
    var layout_changed = interaction.layout_changed;
    switch (interaction.intent) {
        .none, .focus_machine_agent, .peek_machine_agent, .open_machine_worktree => {},
        else => {
            const applied = try applyIntent(client, interaction.intent);
            layout_changed = layout_changed or applied.layout_changed;
        },
    }

    if (layout_changed) {
        client.model.to_host.invalidate_placements = true;
        try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
    }

    return .{
        .consume_pane_input = interaction.consumed or view_interaction.capturesPaneInput(interaction.intent),
    };
}

fn applyIntent(client: *Client, intent: view_interaction.Intent) !IntentOutcome {
    var outcome: IntentOutcome = .{};
    // Any other chrome interaction dismisses the bar panel, as a click
    // outside a popover does.
    if (client.model.bars.panel.isOpen() and !keepsPanel(intent)) {
        try bar_updates.closePanel(client);
    }

    switch (intent) {
        .none, .focus_machine_agent, .peek_machine_agent, .open_machine_worktree => {},
        .toggle_sidebar => {
            _ = try sidebar_toggle.toggleSidebar(client);
        },
        .resize_sidebar => |width| {
            _ = try sidebar_toggle.resizeSidebar(
                client,
                .{
                    .exact = width,
                },
            );
        },
        .toggle_workspace_list => {
            _ = data.workspace_list.toggle(&client.model);
        },
        .machine_picker => _ = name_prompt.openNamePrompt(&client.model, .{ .palette = .machines }),
        .select_machine => |slot| try client.model.to_host.push(.{ .machine = .{ .slot = slot } }),
        .focus_agent => |key| _ = try agent_navigation.navigateAgent(client, key),
        .peek_agent => |key| _ = try agent_peek.open(client, key),
        .select_tab => |tab_id| {
            _ = try tab_selection.selectTab(
                client,
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
        },
        .focus_pane => |pane_id| {
            _ = try pane_focus.applyPaneFocus(client, .{
                .target = .{ .pane_id = pane_id },
                .area = client.geometry().area,
            });
        },
        .move_tab => |move| {
            _ = try tab_move.requestTabMove(
                &client.model,
                .{
                    .location = move.location,
                    .direction = move.direction,
                    .relative_to = move.relative_to,
                },
            );
        },
        .rename_tab => |tab_id| _ = name_prompt.openNamePrompt(
            &client.model,
            .{
                .rename_tab = tab_id,
            },
        ),
        .create_tab => {
            _ = try tab_creation.requestTabCreation(
                client,
                .{},
            );
        },
        .toggle_pane_fullscreen => _ = try pane_resize.togglePaneFullscreen(
            client,
            .{
                .area = client.geometry().area,
            },
        ),
        .select_workspace => |workspace| _ = try workspace_handoff.selectWorkspace(
            client,
            .{
                .workspace = workspace,
            },
        ),
        .notification_activate => |id| _ = try notifications.activateNotificationNow(client, id),
        .notification_dismiss => |id| _ = try notifications.dismissNotificationNow(client, id),
        .attachment_dismiss => |id| outcome.layout_changed = try agent_attachments.dismissAttachment(client, id),
        .diagnostic_dismiss => _ = data.client_diagnostic.clear(&client.model),
        .prompt_row => |index| try name_prompt.choosePromptRow(client, index),
        .bar_component => |component| try bar_components.activate(client, component),
        .panel_component => |index| try bar_components.activatePanel(client, index),
        .toggle_bar_overflow => try bar_updates.toggleOverflow(client),
        .close_panel => try bar_updates.closePanel(client),
    }

    return outcome;
}

fn keepsPanel(intent: view_interaction.Intent) bool {
    return switch (intent) {
        .none, .bar_component, .panel_component, .toggle_bar_overflow, .close_panel => true,
        else => false,
    };
}
