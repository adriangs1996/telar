//! Wires semantic view interactions to existing client use cases.

const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("../../application/input/root.zig");
const agent_navigation = @import("../agents/agent_navigation.zig");
const name_prompts = @import("name_prompts.zig");
const notification_flow = @import("../notifications/notifications.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const sidebar_toggles = @import("../notifications/sidebar_toggles.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

const Client = @import("../../client.zig");
const multiplexer = workspace_capability.multiplexer;
const view_interaction = input_application.view_interaction;

pub const Outcome = view_interaction.Outcome;

const Context = struct {
    client: *Client,
    model: *multiplexer.Model,
};

/// Applies one interaction emitted by the view and returns its pane-input
/// routing decision.
///
/// ```zig
/// const outcome = try apply(client, model, interaction);
/// ```
pub fn apply(client: *Client, model: *multiplexer.Model, interaction: view_interaction.Command) !Outcome {
    var context: Context = .{
        .client = client,
        .model = model,
    };
    var use_case: view_interaction.DispatchViewInteractionHandler = .{
        .effects = .{
            .context = &context,
            .apply_intent = applyIntent,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
        },
    };

    return use_case.execute(interaction);
}

fn applyIntent(raw_context: *anyopaque, intent: view_interaction.Intent) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    const client = context.client;

    switch (intent) {
        .none => {},
        .toggle_sidebar => {
            var use_case = sidebar_toggles.handler(client);

            _ = try use_case.execute();
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
                .area = client.view.workbench(),
            });
        },
        .rename_tab => |tab_id| _ = name_prompts.beginTabRename(client, tab_id),
        .select_workspace => |workspace| _ = try workspace_handoffs.selectWorkspace(client, .{ .workspace = workspace }),
        .notification_activate => |id| _ = try notification_flow.activateNow(client, id),
        .notification_dismiss => |id| _ = try notification_flow.dismissNow(client, id),
    }
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    context.client.graphics_store.invalidatePlacements();
}

fn offerPaneGeometry(raw_context: *anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerAttached(context.client, context.model, context.client.view.workbench());
}
