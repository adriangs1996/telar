const PaneStoreType = @import("../../../pane/PaneStore.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const ReportAgentSession = @import("ReportAgentSession.zig");
const report_agent_session = @import("report_agent_session.zig");
const SessionReferenceType = @import("../../../agent/SessionReference.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");
const ReportAgentSessionHandler = @This();

panes: *const PaneStoreType,
agents: *TrackerType,

/// Validates the reference and stores it on the agent that owns the exact
/// pane generation.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .session = "0192...", .now_ms = now_ms });
/// ```
pub fn execute(handler: *ReportAgentSessionHandler, command: ReportAgentSession) report_agent_session.ReportAgentSessionResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }
    const reference = SessionReferenceType.init(command.session, command.now_ms) catch return .invalid_session;
    const identity = agent_identity.fromPane(pane);

    return if (handler.agents.observeSessionReference(identity, reference)) .recorded else .unchanged;
}
