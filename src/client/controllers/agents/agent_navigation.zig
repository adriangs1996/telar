//! Wires sidebar agent navigation to local focus and runtime handoff adapters.

const Client = @import("../../AttachedClient.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
const ApplicationAgentsAgentNavigationOutcome = @import("../../application/agents/agent_navigation.zig").Outcome;
const NavigateAgentHandlerType = @import("../../application/agents/NavigateAgentHandler.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const TabIdType = @import("telar-core").TabId;
const tab_selections = @import("../tabs/tab_selections.zig");
const PaneIdType = @import("telar-core").PaneId;
const pane_focus = @import("../panes/pane_focus.zig");
const AgentHandoffType = @import("../../model/AgentHandoff.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Resolves one sidebar agent key and applies its local navigation or handoff.
///
/// ```zig
/// const outcome = try apply(client, agent_key);
/// ```
pub fn apply(client: *Client, key: AgentKeyType) !ApplicationAgentsAgentNavigationOutcome {
    var use_case: NavigateAgentHandlerType = .{
        .model = &client.model,
        .handoffs = .{
            .context = client,
            .pending = handoffPending,
        },
        .effects = .{
            .context = client,
            .select_tab = selectTab,
            .focus_pane = focusPane,
            .request_handoff = requestHandoff,
        },
    };

    return use_case.execute(key);
}

fn handoffPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.busy(client);
}

fn selectTab(context: *anyopaque, tab_id: TabIdType) !bool {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case = tab_selections.selectionHandler(client);

    return (try use_case.execute(.{ .target = .{ .tab_id = tab_id } })) != null;
}

fn focusPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case = pane_focus.handler(client);

    _ = try use_case.execute(.{
        .target = .{ .pane_id = pane_id },
        .area = client.geometry().area,
    });
}

fn requestHandoff(context: *anyopaque, handoff: AgentHandoffType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try workspace_handoffs.requestPane(client, handoff.pane_id, handoff.fallback_workspace);
}
