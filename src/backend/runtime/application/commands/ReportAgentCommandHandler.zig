const ReportAgentCommandHandler = @This();
const pane_mod = @import("../../../pane/root.zig");
const ReportAgentCommand = @import("ReportAgentCommand.zig");
const source_namespace = @import("report_agent_command.zig");
panes: *pane_mod.PaneStore,

/// Queues one start or finish report against the exact live pane.
///
/// ```zig
/// const outcome = handler.execute(report);
/// ```
pub fn execute(handler: *ReportAgentCommandHandler, report: ReportAgentCommand) source_namespace.Outcome {
    const pane = handler.panes.resolve(report.pane) orelse return .pane_not_found;
    if (pane.exit != null) {
        return .pane_not_found;
    }

    const queued = pane.recordAgentCommand(.{
        .command = .{
            .bytes = report.command,
            .cwd = report.cwd,
            .started_at_ms = report.now_ms,
            .duration_ns = 0,
            .exit_code = report.exit_code,
            .status = .completed,
            .truncated = false,
        },
        .provider = report.provider,
        .tool_call_id = report.tool_call_id,
        .origin = .hook,
        .phase = report.phase,
    });
    return if (queued) .applied else .queue_full;
}
