const ReportAgentTitleHandler = @This();
const source_namespace = @import("report_agent_title.zig");
const ReportAgentTitle = @import("ReportAgentTitle.zig");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
panes: *const source_namespace.PaneStore,
agents: *source_namespace.Tracker,

/// Applies the title to the agent that owns the exact pane generation.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .title = "Fix proxy" });
/// ```
pub fn execute(handler: *ReportAgentTitleHandler, command: ReportAgentTitle) source_namespace.ReportAgentTitleResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const identity = agent_identity.fromPane(pane);
    const changed = handler.agents.reportTitle(identity, command.title) catch return .invalid_title;

    return if (changed) .recorded else .unchanged;
}
