//! Wires semantic view interactions to existing client use cases.

const data = @import("model");
const view_interaction = @import("../../application/input/view_interaction.zig");
const Client = @import("../../AttachedClient.zig");
const ViewInteractionCommand = @import("../../application/input/ViewInteractionCommand.zig");
const ViewInteractionOutcome = @import("../../application/input/ViewInteractionOutcome.zig");
const ViewInteractionsContext = @import("ViewInteractionsContext.zig");
const IntentOutcomeType = @import("../../application/input/IntentOutcome.zig");

/// Applies one interaction emitted by the view and returns its pane-input
/// routing decision.
///
/// ```zig
/// const outcome = try apply(client, model, interaction);
/// ```
pub fn apply(client: *Client, model: *data.MultiplexerModel, interaction: ViewInteractionCommand) !ViewInteractionOutcome {
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

fn applyIntent(context: *ViewInteractionsContext, intent: view_interaction.Intent) !IntentOutcomeType {
    const client = context.client;
    var outcome: IntentOutcomeType = .{};

    switch (intent) {
        .none => {},
        .toggle_sidebar => {
            _ = try client.toggleSidebar();
        },
        .resize_sidebar => |width| {
            _ = try client.resizeSidebar(
                .{
                    .exact = width,
                },
            );
        },
        .toggle_workspace_list => {
            _ = client.model.toggleWorkspaceList();
        },
        .focus_agent => |key| _ = try client.navigateAgent(key),
        .select_tab => |tab_id| {
            _ = try client.selectTab(
                .{
                    .target = .{
                        .tab_id = tab_id,
                    },
                },
            );
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
        .rename_tab => |tab_id| _ = client.openNamePrompt(
            .{
                .rename_tab = tab_id,
            },
        ),
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
        .attachment_dismiss => |id| outcome.layout_changed = try client.dismissAttachment(id),
        .prompt_row => |index| try client.choosePromptRow(index),
    }

    return outcome;
}
