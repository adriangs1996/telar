const core = @import("telar-core");
const Pane = @import("Pane.zig");
const Stats = @import("../history/Stats.zig");
const Command = @import("../history/Command.zig");
const CaptureContext = @This();

pane: *Pane,
observation_stats: ?*Stats = null,

pub fn emit(self: *CaptureContext, command: Command) void {
    const pane = self.pane;
    if (!pane.history_session_started) {
        return;
    }
    const sequence = pane.history_sequence.reserve() orelse {
        if (self.observation_stats) |stats| {
            stats.dropped += 1;
        }

        return;
    };
    var author: core.HistoryAuthor = .human;
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
    if (self.observation_stats) |stats| {
        if (submitted) {
            stats.captured += 1;
        } else {
            stats.dropped += 1;
        }
    }
}
