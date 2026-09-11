const ReportAgentHandler = @This();
const source_namespace = @import("report_agent.zig");
const ReportAgent = @import("ReportAgent.zig");
const ReportAgentResult = @import("ReportAgentResult.zig");
const agent_mod = @import("../../../agent/root.zig");
const agent_identity = @import("../coordinators/root.zig").agent_identity;
panes: *const source_namespace.PaneStore,
agents: *source_namespace.Tracker,

/// Applies the report to the agent of the exact pane generation and
/// returns the projected status before and after, so the caller can
/// publish the audible transition.
///
/// ```zig
/// const result = handler.execute(.{ .pane = key, .state = .working, .session = "", .now_ms = now_ms });
/// ```
pub fn execute(handler: *ReportAgentHandler, command: ReportAgent) ReportAgentResult {
    const pane = handler.panes.resolveConst(command.pane) orelse return .{ .outcome = .pane_not_found };
    if (pane.exit != null) {
        return .{ .outcome = .pane_not_found };
    }
    const session: ?agent_mod.SessionReference = if (command.session.len == 0)
        null
    else
        agent_mod.SessionReference.init(command.session, command.now_ms) catch return .{ .outcome = .invalid_session };
    const identity = agent_identity.fromPane(pane);
    const previous = handler.agents.projectedStatus(identity.key);
    const had_session = handler.agents.sessionReference(identity.key) != null;

    const changed = handler.agents.observeReport(.{
        .identity = identity,
        .state = command.state,
        .observed_at_ms = command.now_ms,
        .observed_at_ns = command.now_ns,
        .session = session,
        .session_file = command.session_file,
    });
    const current = handler.agents.projectedStatus(identity.key);

    return .{
        .outcome = if (changed) .applied else .unchanged,
        .previous = previous,
        .current = current,
        .session_recorded = session != null and !had_session,
    };
}
