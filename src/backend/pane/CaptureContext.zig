const PaneType = @import("Pane.zig");
const StatsType = @import("../history/Stats.zig");
const CommandType = @import("../history/Command.zig");
const HistoryAuthorType = @import("telar-core").HistoryAuthor;
const CaptureContext = @This();

pane: *PaneType,
observation_stats: ?*StatsType = null,

pub fn emit(context: *CaptureContext, command: CommandType) void {
    const pane = context.pane;
    if (!pane.history_session_started) {
        return;
    }
    const sequence = pane.history_sequence.reserve() orelse {
        if (context.observation_stats) |stats| {
            stats.dropped += 1;
        }

        return;
    };
    var author: HistoryAuthorType = .human;
    if (pane.injected_submissions.load(.monotonic) > 0) {
        _ = pane.injected_submissions.fetchSub(1, .monotonic);
        author = .agent;
    }

    const submitted = pane.history_service.recordCommand(pane.io, .{
        .context = .{
            .author = author,
            .session_id = pane.history_session_id,
            .pane_id = pane.id,
            .location = pane.location,
            .sequence = sequence,
            .workspace_path = pane.workspace_path,
            .cols = pane.history_observer.terminal.cols,
            .rows = pane.history_observer.terminal.rows,
        },
        .command = command,
    });
    if (context.observation_stats) |stats| {
        if (submitted) {
            stats.captured += 1;
        } else {
            stats.dropped += 1;
        }
    }
}
