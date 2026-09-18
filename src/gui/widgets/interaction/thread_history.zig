//! Reading offsets are committed only after their exact window reaches the host.
const GuiClient = @import("../../GuiClient.zig");
const client = @import("telar-client");

/// Commits page-anchor geometry before scheduling any new history request.
/// Example: `try thread_history.delivered(gui);`
pub fn delivered(gui: *GuiClient) !void {
    const registry = gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.action != .transcript or (!target.thread_reanchor and !target.thread_skip_folded and target.thread_prefetch == null)) {
            continue;
        }
        if (gui.widgets.thread_anchor.pending) |pending| {
            if (pending.control.pane_id == target.action.transcript) {
                continue;
            }
        }
        const pane = gui.app.model.agentPane(target.action.transcript) orelse continue;
        if (pane.attachment_generation != target.id.generation or pane.history_generation != target.thread_history_generation or pane.transcript_scroll != target.thread_scroll_value or pane.transcript_anchor_revision != target.thread_anchor_revision) {
            continue;
        }
        const revision = if (pane.agent_history) |window| window.revision else if (pane.agent_thread) |snapshot| snapshot.revision else 0;
        if (revision != target.thread_window_revision) {
            continue;
        }
        if (target.thread_reanchor) {
            client.agent_history.anchor(&gui.app, pane.id, target.thread_resolved_scroll);
        }
        if (target.thread_skip_folded) {
            client.agent_history.skipFolded(&gui.app, pane.id);
        } else if (target.thread_prefetch) |direction| {
            client.agent_history.prefetch(&gui.app, pane.id, direction);
        }
    }
    try client.agent_history.flush(&gui.app);
}
