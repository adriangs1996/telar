const PaneStoreType = @import("../../../pane/PaneStore.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const ReportAgentTitle = @import("ReportAgentTitle.zig");
const report_agent_title = @import("report_agent_title.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");
const ReportAgentTitleHandler = @This();

panes: *const PaneStoreType,
agents: *TrackerType,

/// Applies the title to the agent that owns the exact pane generation.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .title = "Fix proxy" });
/// ```
pub fn execute(handler: *ReportAgentTitleHandler, command: ReportAgentTitle) report_agent_title.ReportAgentTitleResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const identity = agent_identity.fromPane(pane);
    const changed = handler.agents.reportTitle(identity, command.title) catch return .invalid_title;

    return if (changed) .recorded else .unchanged;
}
