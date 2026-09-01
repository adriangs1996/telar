//! Wires sidebar agent navigation to local focus and runtime handoff adapters.

const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const agents_application = @import("application/agents/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_selections = @import("tab_selections.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");

const Client = @import("client.zig");
const agent_navigation = agents_application.agent_navigation;
const schema = core.schema;

pub const Outcome = agent_navigation.Outcome;

/// Resolves one sidebar agent key and applies its local navigation or handoff.
///
/// ```zig
/// const outcome = try apply(client, agent_key);
/// ```
pub fn apply(client: *Client, key: agents.AgentKey) !Outcome {
    var use_case: agent_navigation.NavigateAgentHandler = .{
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

fn selectTab(context: *anyopaque, tab_id: schema.TabId) !bool {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case = tab_selections.selectionHandler(client);

    return (try use_case.execute(.{ .target = .{ .tab_id = tab_id } })) != null;
}

fn focusPane(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case = pane_focus.handler(client);

    _ = try use_case.execute(.{
        .target = .{ .pane_id = pane_id },
        .area = client.view.workbench(),
    });
}

fn requestHandoff(context: *anyopaque, handoff: client_model.AgentHandoff) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try workspace_handoffs.requestPane(client, handoff.pane_id, handoff.fallback_workspace);
}
