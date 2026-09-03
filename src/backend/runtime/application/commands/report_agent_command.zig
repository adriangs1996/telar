//! Application command for shell-tool reports emitted by official agent hooks.

const std = @import("std");
const core = @import("telar-core");
const history = @import("../../../history/root.zig");
const pane_mod = @import("../../../pane/root.zig");

const schema = core.schema;

pub const ReportAgentCommand = struct {
    pane: pane_mod.PaneKey,
    phase: schema.AgentCommandPhase,
    provider: []const u8,
    tool_call_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    exit_code: ?i32,
    now_ms: i64,
};

pub const Outcome = enum { applied, pane_not_found, queue_full };

pub const ReportAgentCommandHandler = struct {
    panes: *pane_mod.PaneStore,
    history_service: *history.Service,

    /// Queues one start or finish report against the exact live pane.
    ///
    /// ```zig
    /// const outcome = handler.execute(report);
    /// ```
    pub fn execute(handler: *ReportAgentCommandHandler, report: ReportAgentCommand) Outcome {
        const pane = handler.panes.resolve(report.pane) orelse return .pane_not_found;
        if (pane.exit != null) {
            return .pane_not_found;
        }

        pane.history_sequence += 1;
        const queued = handler.history_service.recordAgentCommand(pane.io, .{
            .context = .{
                .session_id = pane.history_session_id,
                .pane_id = pane.id,
                .location = pane.location,
                .sequence = pane.history_sequence,
                .workspace_path = pane.workspace_path,
                .cols = pane.history_observer.terminal.cols,
                .rows = pane.history_observer.terminal.rows,
            },
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
};
