//! Wires semantic view interactions to existing client use cases.

const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const ViewInteractionCommand = @import("../../application/input/ViewInteractionCommand.zig");
const ViewInteractionOutcome = @import("../../application/input/ViewInteractionOutcome.zig");
const ViewInteractionsContext = @import("ViewInteractionsContext.zig");
const DispatchViewInteractionHandlerType = @import("../../application/input/DispatchViewInteractionHandler.zig");
const IntentType = @import("../../application/input/view_interaction.zig").Intent;
const IntentOutcomeType = @import("../../application/input/IntentOutcome.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const name_prompts = @import("name_prompts.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const notification_flow = @import("../notifications/notifications.zig");
const attachment_prompts = @import("attachment_prompts.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");

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
    var use_case: DispatchViewInteractionHandlerType = .{
        .effects = .{
            .context = &context,
            .apply_intent = applyIntent,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
        },
    };

    return use_case.execute(interaction);
}

fn applyIntent(raw_context: *anyopaque, intent: IntentType) !IntentOutcomeType {
    const context: *ViewInteractionsContext = @ptrCast(@alignCast(raw_context));
    const client = context.client;
    var outcome: IntentOutcomeType = .{};

    switch (intent) {
        .none => {},
        .toggle_sidebar => {
            var use_case = sidebar_toggles.handler(client);

            _ = try use_case.execute();
        },
        .resize_sidebar => |width| {
            var use_case = sidebar_toggles.resizeHandler(client);

            _ = try use_case.execute(.{ .exact = width });
        },
        .toggle_workspace_list => {
            _ = client.model.toggleWorkspaceList();
        },
        .focus_agent => |key| _ = try agent_navigation.apply(client, key),
        .select_tab => |tab_id| {
            var use_case = tab_selections.selectionHandler(client);

            _ = try use_case.execute(.{ .target = .{ .tab_id = tab_id } });
        },
        .focus_pane => |pane_id| {
            var use_case = pane_focus.handler(client);

            _ = try use_case.execute(.{
                .target = .{ .pane_id = pane_id },
                .area = client.geometry().area,
            });
        },
        .rename_tab => |tab_id| _ = name_prompts.beginTabRename(client, tab_id),
        .select_workspace => |workspace| _ = try workspace_handoffs.selectWorkspace(client, .{ .workspace = workspace }),
        .notification_activate => |id| _ = try notification_flow.activateNow(client, id),
        .notification_dismiss => |id| _ = try notification_flow.dismissNow(client, id),
        .attachment_dismiss => |id| outcome.layout_changed = try attachment_prompts.dismiss(client, id),
    }

    return outcome;
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const context: *ViewInteractionsContext = @ptrCast(@alignCast(raw_context));

    context.client.host_graphics.invalidatePlacements();
}

fn offerPaneGeometry(raw_context: *anyopaque) !void {
    const context: *ViewInteractionsContext = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerAttached(context.client, context.model, context.client.geometry().area);
}
