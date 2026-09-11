const ReportAgentSessionHandler = @This();
const source_namespace = @import("report_agent_session.zig");
const ReportAgentSession = @import("ReportAgentSession.zig");
const agent_mod = @import("../../../agent/root.zig");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
panes: *const source_namespace.PaneStore,
agents: *source_namespace.Tracker,

/// Validates the reference and stores it on the agent that owns the exact
/// pane generation.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .session = "0192...", .now_ms = now_ms });
/// ```
pub fn execute(handler: *ReportAgentSessionHandler, command: ReportAgentSession) source_namespace.ReportAgentSessionResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }
    const reference = agent_mod.SessionReference.init(command.session, command.now_ms) catch return .invalid_session;
    const identity = agent_identity.fromPane(pane);

    return if (handler.agents.observeSessionReference(identity, reference)) .recorded else .unchanged;
}
