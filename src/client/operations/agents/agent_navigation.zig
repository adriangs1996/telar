//! Wires sidebar agent navigation to local focus and runtime handoff adapters.

const Client = @import("../../AttachedClient.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
pub const Outcome = enum { ignored, focused, handoff_requested };
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const tab_selections = @import("../tabs/tab_selections.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Resolves one sidebar agent key and applies its local navigation or handoff.
///
/// ```zig
/// const outcome = try apply(client, agent_key);
/// ```
pub fn apply(client: *Client, key: AgentKeyType) !Outcome {
    const plan = client.model.planAgentNavigation(key) orelse return .ignored;
    return switch (plan) {
        .local => |local| local: {
            if (local.select_tab) |tab_id| {
                if (try tab_selections.select(client, .{ .target = .{ .tab_id = tab_id } }) == null) {
                    break :local .ignored;
                }
            }
            _ = try pane_focus.apply(client, .{ .target = .{ .pane_id = local.pane_id }, .area = client.geometry().area });
            break :local .focused;
        },
        .handoff => |handoff| handoff: {
            if (request_lifecycle.busy(client)) {
                break :handoff .ignored;
            }
            _ = try workspace_handoffs.requestPane(client, handoff.pane_id, handoff.fallback_workspace);
            break :handoff .handoff_requested;
        },
    };
}
