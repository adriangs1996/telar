//! Planning a move to another agent's pane from the sidebar or a binding.

const model_data = @import("../model.zig");
const sidebar = @import("../layout/sidebar.zig");
const ClientModel = @import("../state/ClientModel.zig");
const LocalAgentNavigation = @import("../state/LocalAgentNavigation.zig");
const AgentHandoff = @import("../state/AgentHandoff.zig");

/// Resolves a sidebar identity into local focus or a runtime handoff
/// without exposing agent replica storage to the input adapter.
///
/// ```zig
/// const plan = agent_navigation.planMove(model, key) orelse return;
/// ```
pub fn planMove(model: *const ClientModel, key: model_data.AgentKey) ?AgentNavigationPlan {
    const agent = model.agent_snapshot.find(key) orelse return null;
    if (model.panes.findConst(key.pane_id)) |pane| {
        const active = model.tabs.activeSlot() orelse return null;
        const tab_id = pane.location.tab_id;

        return .{ .local = .{
            .pane_id = key.pane_id,
            .select_tab = if (model.tabs.location[active].tab_id == tab_id) null else tab_id,
        } };
    }

    return .{ .handoff = .{
        .pane_id = key.pane_id,
        .fallback_workspace = switch (agent.location.workspace) {
            .workspace => |workspace| workspace,
            .worktree => null,
        },
    } };
}

const AgentNavigationPlan = union(enum) {
    local: LocalAgentNavigation,
    handoff: AgentHandoff,
};
