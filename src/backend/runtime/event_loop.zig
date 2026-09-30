//! Bounded space for every admitted actor to publish while cancellation joins.

const client_store = @import("client/store_support.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const event = @import("event.zig");
const ReviewJobs = @import("../change_review/Jobs.zig");
const PathIndexes = @import("../paths/PathIndexes.zig");
const std = @import("std");

const Tag = std.meta.Tag(event.Event);

// An occupied slot includes a completed actor whose event is still queued.
// Select.cancel joins before draining, so its queue must fit all such slots.
// Counting mutually exclusive pane phases separately leaves bounded spare room.
pub const event_capacity = capacity: {
    var total: usize = 0;
    for (std.enums.values(Tag)) |tag| {
        total += producerSlots(tag);
    }
    break :capacity total;
};

fn producerSlots(tag: Tag) usize {
    return switch (tag) {
        .client_message, .client_sent, .pane_search, .pane_descent => client_store.max_clients,
        .pane_input_written,
        .pane_response_written,
        .pane_output,
        .pane_ingested,
        .pane_observed,
        .pane_media,
        .pane_exit,
        => PaneStore.capacity,
        .change_review_completed => @as(ReviewJobs, .{}).items.len,
        .handshaken => client_store.max_pending_handshakes,
        .path_index_built, .paths_found => PathIndexes.capacity,
        // Each source retains one global pending flag, admission slot or waiter.
        // Git uses workspace State.git_probe, which survives workspace removal.
        .accepted,
        .cell_publication_due,
        .history_response,
        .telemetry_tick,
        .telemetry_written,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .metrics_tick,
        .metrics_sampled,
        .checkpoint_written,
        .git_status,
        .worktree_git,
        .worktree_detected,
        .editor_opened,
        .session_name,
        .stopped,
        => 1,
    };
}
