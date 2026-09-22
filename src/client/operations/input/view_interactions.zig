//! Wires semantic view interactions to existing client use cases.

const view_interaction = @import("../../application/input/view_interaction.zig");
const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const ViewInteractionCommand = @import("../../application/input/ViewInteractionCommand.zig");
const ViewInteractionOutcome = @import("../../application/input/ViewInteractionOutcome.zig");
const ViewInteractionsContext = @import("ViewInteractionsContext.zig");
const IntentType = @import("../../application/input/view_interaction.zig").Intent;
const IntentOutcomeType = @import("../../application/input/IntentOutcome.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const name_prompts = @import("name_prompts.zig");
const attachment_prompts = @import("attachment_prompts.zig");

/// Applies one interaction emitted by the view and returns its pane-input
/// routing decision.
///
/// ```zig
/// const outcome = try apply(client, model, interaction);
/// ```
pub fn apply(client: *Client, model: *MultiplexerModel, interaction: ViewInteractionCommand) !ViewInteractionOutcome {
    var context: ViewInteractionsContext = .{
        .client = client,
        .model = model,
    };
    var layout_changed = interaction.layout_changed;
    switch (interaction.intent) {
        .none => {},
        else => {
            const applied = try applyIntent(&context, interaction.intent);
            layout_changed = layout_changed or applied.layout_changed;
        },
    }

    if (layout_changed) {
        client.host_graphics.invalidatePlacements();
        try client.resizeAttachedPanes(model, client.geometry().area);
    }

    return .{
        .consume_pane_input = interaction.consumed or view_interaction.capturesPaneInput(interaction.intent),
    };
}

fn applyIntent(context: *ViewInteractionsContext, intent: IntentType) !IntentOutcomeType {
    const client = context.client;
    var outcome: IntentOutcomeType = .{};

    switch (intent) {
        .none => {},
        .toggle_sidebar => {
            _ = try sidebar_toggles.toggle(client);
        },
        .resize_sidebar => |width| {
            _ = try sidebar_toggles.resize(client, .{ .exact = width });
        },
        .toggle_workspace_list => {
            _ = client.model.toggleWorkspaceList();
        },
        .focus_agent => |key| _ = try agent_navigation.apply(client, key),
        .select_tab => |tab_id| {
            _ = try tab_selections.select(client, .{ .target = .{ .tab_id = tab_id } });
        },
        .focus_pane => |pane_id| {
            _ = try client.applyPaneFocus(.{
                .target = .{ .pane_id = pane_id },
                .area = client.geometry().area,
            });
        },
        .move_tab => |move| {
            _ = try client.requestTabMove(
                .{
                    .location = move.location,
                    .direction = move.direction,
                    .relative_to = move.relative_to,
                },
            );
        },
        .rename_tab => |tab_id| _ = name_prompts.beginTabRename(client, tab_id),
        .create_tab => {
            _ = try client.requestTabCreation(
                .{},
            );
        },
        .select_workspace => |workspace| _ = try client.selectWorkspace(
            .{
                .workspace = workspace,
            },
        ),
        .notification_activate => |id| _ = try client.activateNotificationNow(id),
        .notification_dismiss => |id| _ = try client.dismissNotificationNow(id),
        .attachment_dismiss => |id| outcome.layout_changed = try attachment_prompts.dismiss(client, id),
        .prompt_row => |index| try name_prompts.chooseRow(client, index),
    }

    return outcome;
}
