//! Agent navigation: moves focus to the next agent that needs attention.
const data = @import("model");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_selection = @import("../workspace/tab_selection.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const Client = @import("../AttachedClient.zig");

const AgentNavigationOutcome = enum { ignored, focused, handoff_requested };

/// Resolves one sidebar agent key and applies its local navigation or handoff.
/// Example: `_ = try agent_navigation.navigateAgent(app, key);`
pub fn navigateAgent(client: *Client, key: data.AgentKey) !AgentNavigationOutcome {
    const plan = client.model.planAgentNavigation(key) orelse return .ignored;
    return switch (plan) {
        .local => |local| local: {
            if (local.select_tab) |tab_id| {
                if (try tab_selection.selectTab(
                    client,
                    .{
                        .target = .{
                            .tab_id = tab_id,
                        },
                    },
                ) == null) {
                    break :local .ignored;
                }
            }
            _ = try pane_focus.applyPaneFocus(
                client,
                .{
                    .target = .{
                        .pane_id = local.pane_id,
                    },
                    .area = client.geometry().area,
                },
            );
            break :local .focused;
        },
        .handoff => |handoff| handoff: {
            if (!client.model.request_lifecycle.tracker.isEmpty()) {
                break :handoff .ignored;
            }
            _ = try workspace_handoff.requestWorkspacePane(client, handoff.pane_id, handoff.fallback_workspace);
            break :handoff .handoff_requested;
        },
    };
}
