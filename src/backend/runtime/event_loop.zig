//! Bounded space for every admitted actor to publish while cancellation joins.

const client_store = @import("client/store_support.zig");
const core = @import("telar-core");
const event = @import("event.zig");
const ReviewJobs = @import("../change_review/Jobs.zig");
const AgentHistoryJobs = @import("application/AgentHistoryJobs.zig");
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
        .client_message, .client_sent, .pane_search => client_store.max_clients,
        .pane_input_written,
        .pane_response_written,
        .pane_output,
        .pane_ingested,
        .pane_observed,
        .pane_media,
        .pane_exit,
        .agent_thread_changed,
        => core.max_panes_per_tab,
        .change_review_completed => @as(ReviewJobs, .{}).items.len,
        .agent_history_completed => @as(AgentHistoryJobs, .{}).items.len,
        // Each source retains one global pending flag, admission slot or waiter.
        // Git uses workspace State.git_probe, which survives workspace removal.
        .accepted,
        .handshaken,
        .cell_publication_due,
        .history_response,
        .telemetry_tick,
        .telemetry_written,
        .proxy_event,
        .proxy_capture,
        .plugin_effects,
        .agent_tick,
        .agent_description,
        .engine_response,
        .metrics_tick,
        .metrics_sampled,
        .checkpoint_written,
        .git_status,
        .editor_opened,
        .session_name,
        .stopped,
        => 1,
    };
}
