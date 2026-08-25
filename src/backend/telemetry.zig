//! Runtime metrics and their diagnostics serialization.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const graphics_sync = @import("graphics_sync.zig");
const history = @import("history/root.zig");
const pane_mod = @import("pane.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const AttachmentStore = graphics_sync.AttachmentStore;
const PaneStore = pane_mod.PaneStore;

pub const RuntimeMetrics = struct {
    started_ns: u64,
    client_messages: u64 = 0,
    stale_client_messages: u64 = 0,
    stale_pane_events: u64 = 0,
    geometry_rejections: u64 = 0,
    input_events: u64 = 0,
    input_bytes: u64 = 0,
    input_write: diagnostics.Timing = .{},
    pty_events: u64 = 0,
    pty_bytes: u64 = 0,
    frames: u64 = 0,
    frame_bytes: u64 = 0,
    frame_cells: u64 = 0,
    frame_spans: u64 = 0,
    snapshots: u64 = 0,
    cursor_only_frames: u64 = 0,
    noop_frames: u64 = 0,
    damaged_rows: u64 = 0,
    diff_scanned_cells: u64 = 0,
    coalesced_spans: u64 = 0,
    bridged_cells: u64 = 0,
    coalesced_bytes_saved: u64 = 0,
    folded_pty_events: u64 = 0,
    graphics_messages: u64 = 0,
    graphics_bytes: u64 = 0,
    media_bytes: u64 = 0,
    media_discarded_frames: u64 = 0,
    media_resets: u64 = 0,
    media_failures: u64 = 0,
    decode: diagnostics.Timing = .{},
    ingest: diagnostics.Timing = .{},
    encode: diagnostics.Timing = .{},
    ack: diagnostics.Timing = .{},
    history_captured: u64 = 0,
    history_dropped: u64 = 0,
    history_candidate_input_bytes: u64 = 0,
    history_queries: u64 = 0,
    history_query_failures: u64 = 0,
    history_observation_resets: u64 = 0,
    history_observation_failures: u64 = 0,
    proxy_observations: u64 = 0,
    client_resyncs: u64 = 0,
};

pub fn formatRuntimeTelemetry(
    buffer: []u8,
    io: Io,
    metrics: *const RuntimeMetrics,
    attachment_stores: []const *const AttachmentStore,
    client_count: usize,
    workspace_count: usize,
    tab_count: usize,
    panes: *const PaneStore,
    history_service: *const history.Service,
    response_queue_depth: usize,
    response_queue_dropped: u64,
    proxy_active: bool,
    proxy_active_connections: u32,
    proxy_dropped_events: u64,
    proxy_rejected_connections: u64,
    proxy_connection_limit_drops: u64,
    proxy_h2_decode_failures: u64,
) ![]const u8 {
    const now_ns = diagnostics.now(io);
    var outstanding_frames: usize = 0;
    var dirty_panes: usize = 0;
    var attachment_count: usize = 0;
    var history_prompt_markers: u64 = 0;
    var history_input_markers: u64 = 0;
    var history_output_markers: u64 = 0;
    var history_finished_markers: u64 = 0;
    var history_osc_started: u64 = 0;
    var history_osc_finished: u64 = 0;
    var history_pty_submissions: u64 = 0;
    var history_pty_captures: u64 = 0;
    var history_pty_capture_failures: u64 = 0;
    var history_foreground_completions: u64 = 0;
    var history_next_input_completions: u64 = 0;
    var history_auxiliary_completions: u64 = 0;
    var graphics_images: usize = 0;
    var graphics_placements: usize = 0;
    var graphics_resident_bytes: usize = 0;
    var graphics_transfer_bytes: usize = 0;
    var graphics_loading_bytes: usize = 0;
    var media_queue_events: usize = 0;
    var media_queue_bytes: usize = 0;
    var media_dropped_events: u64 = 0;
    var media_dropped_bytes: u64 = 0;
    var pty_response_queue_depth: usize = 0;
    var pty_response_dropped: u64 = 0;
    var pane_input_queue_depth: usize = 0;
    var pane_input_dropped_bytes: u64 = 0;
    var history_input_dropped: u64 = 0;
    for (panes.items) |slot| {
        const pane = slot orelse continue;
        if (pane.ingest_pending) continue;
        pty_response_queue_depth += pane.pty_responses.len;
        pty_response_dropped += pane.pty_responses.dropped;
        pane_input_queue_depth += pane.input_queue.len;
        pane_input_dropped_bytes +|= pane.input_queue.dropped_bytes;
        history_input_dropped +|= pane.history_observer.dropped_events;
        media_dropped_events +|= pane.media.dropped_events;
        media_dropped_bytes +|= pane.media.dropped_bytes;
        for (&pane.media.batches) |*batch| {
            media_queue_events += batch.event_count;
            media_queue_bytes += batch.len;
        }
        if (pane.dirty) dirty_panes += 1;
        if (pane.history_observer.worker == null) {
            history_prompt_markers += pane.history_observer.tracker.aux.prompt_markers;
            history_input_markers += pane.history_observer.tracker.aux.input_markers;
            history_output_markers += pane.history_observer.tracker.aux.output_markers;
            history_finished_markers += pane.history_observer.tracker.aux.finished_markers;
            history_osc_started += pane.history_observer.tracker.aux.osc_started;
            history_osc_finished += pane.history_observer.tracker.aux.osc_finished;
            history_pty_submissions += pane.history_observer.tracker.submissions_armed;
            history_pty_captures += pane.history_observer.tracker.submissions_captured;
            history_pty_capture_failures += pane.history_observer.tracker.capture_failures;
            history_foreground_completions += pane.history_observer.tracker.foreground_completions;
            history_next_input_completions += pane.history_observer.tracker.next_input_completions;
            history_auxiliary_completions += pane.history_observer.tracker.auxiliary_completions;
        }
        if (pane.media.worker == null) {
            for (std.enums.values(vt.ScreenSet.Key)) |key| {
                const screen = pane.media.terminal.screens.get(key) orelse continue;
                graphics_images += screen.kitty_images.images.count();
                graphics_placements += screen.kitty_images.placements.count();
                graphics_resident_bytes += screen.kitty_images.total_bytes;
                if (screen.kitty_images.loading) |loading|
                    graphics_loading_bytes += loading.data.items.len;
            }
        }
    }
    for (attachment_stores) |attachments| {
        attachment_count += attachments.count;
        for (attachments.items) |slot| {
            const active = slot orelse continue;
            if (active.pane.ingest_pending) continue;
            if (active.transfer) |transfer| {
                graphics_transfer_bytes += transfer.pixels.len;
                graphics_resident_bytes += transfer.pixels.len;
            }
            if (active.outstanding_frame_id != 0) outstanding_frames += 1;
        }
    }
    const history_stats = history_service.statsSnapshot();
    var output = Io.Writer.fixed(buffer);
    try output.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"runtime\"," ++
        "\"client_count\":{d},\"workspace_count\":{d},\"tab_count\":{d}," ++
        "\"pane_count\":{d},\"attachment_count\":{d}," ++
        "\"outstanding_frames\":{d},\"dirty_panes\":{d}," ++
        "\"client_messages\":{d},\"stale_client_messages\":{d}," ++
        "\"stale_pane_events\":{d},\"geometry_rejections\":{d}," ++
        "\"input_events\":{d},\"input_bytes\":{d}," ++
        "\"pty_events\":{d},\"pty_bytes\":{d},\"folded_pty_events\":{d}," ++
        "\"frames\":{d},\"frame_bytes\":{d},\"frame_cells\":{d}," ++
        "\"frame_spans\":{d},\"snapshots\":{d}," ++
        "\"cursor_only_frames\":{d},\"noop_frames\":{d}," ++
        "\"damaged_rows\":{d},\"diff_scanned_cells\":{d}," ++
        "\"coalesced_spans\":{d},\"bridged_cells\":{d}," ++
        "\"coalesced_bytes_saved\":{d},", .{
        now_ns / std.time.ns_per_ms,
        diagnostics.elapsed(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        client_count,
        workspace_count,
        tab_count,
        panes.count,
        attachment_count,
        outstanding_frames,
        dirty_panes,
        metrics.client_messages,
        metrics.stale_client_messages,
        metrics.stale_pane_events,
        metrics.geometry_rejections,
        metrics.input_events,
        metrics.input_bytes,
        metrics.pty_events,
        metrics.pty_bytes,
        metrics.folded_pty_events,
        metrics.frames,
        metrics.frame_bytes,
        metrics.frame_cells,
        metrics.frame_spans,
        metrics.snapshots,
        metrics.cursor_only_frames,
        metrics.noop_frames,
        metrics.damaged_rows,
        metrics.diff_scanned_cells,
        metrics.coalesced_spans,
        metrics.bridged_cells,
        metrics.coalesced_bytes_saved,
    });
    try output.print(
        "\"graphics_messages\":{d},\"graphics_bytes\":{d}," ++
            "\"media_bytes\":{d},\"media_discarded_frames\":{d}," ++
            "\"media_resets\":{d},\"media_failures\":{d}," ++
            "\"media_queue_events\":{d},\"media_queue_bytes\":{d}," ++
            "\"media_dropped_events\":{d},\"media_dropped_bytes\":{d}," ++
            "\"graphics_images\":{d},\"graphics_placements\":{d}," ++
            "\"graphics_resident_bytes\":{d},\"graphics_transfer_bytes\":{d}," ++
            "\"graphics_loading_bytes\":{d}," ++
            "\"pty_response_queue_depth\":{d},\"pty_response_dropped\":{d}," ++
            "\"pane_input_queue_depth\":{d},\"pane_input_dropped_bytes\":{d}," ++
            "\"response_queue_depth\":{d},\"response_queue_dropped\":{d},",
        .{
            metrics.graphics_messages,
            metrics.graphics_bytes,
            metrics.media_bytes,
            metrics.media_discarded_frames,
            metrics.media_resets,
            metrics.media_failures,
            media_queue_events,
            media_queue_bytes,
            media_dropped_events,
            media_dropped_bytes,
            graphics_images,
            graphics_placements,
            graphics_resident_bytes,
            graphics_transfer_bytes,
            graphics_loading_bytes,
            pty_response_queue_depth,
            pty_response_dropped,
            pane_input_queue_depth,
            pane_input_dropped_bytes,
            response_queue_depth,
            response_queue_dropped,
        },
    );
    try output.print("\"history_captured\":{d},\"history_dropped\":{d}," ++
        "\"history_candidate_input_bytes\":{d},\"history_input_dropped\":{d}," ++
        "\"history_prompt_markers\":{d},\"history_input_markers\":{d}," ++
        "\"history_output_markers\":{d},\"history_finished_markers\":{d}," ++
        "\"history_osc_started\":{d},\"history_osc_finished\":{d}," ++
        "\"history_pty_submissions\":{d},\"history_pty_captures\":{d}," ++
        "\"history_pty_capture_failures\":{d}," ++
        "\"history_foreground_completions\":{d}," ++
        "\"history_next_input_completions\":{d}," ++
        "\"history_auxiliary_completions\":{d},", .{
        metrics.history_captured,
        metrics.history_dropped,
        metrics.history_candidate_input_bytes,
        history_input_dropped,
        history_prompt_markers,
        history_input_markers,
        history_output_markers,
        history_finished_markers,
        history_osc_started,
        history_osc_finished,
        history_pty_submissions,
        history_pty_captures,
        history_pty_capture_failures,
        history_foreground_completions,
        history_next_input_completions,
        history_auxiliary_completions,
    });
    try output.print(
        "\"proxy_active\":{d},\"proxy_observations\":{d}," ++
            "\"proxy_active_connections\":{d},\"proxy_dropped_events\":{d}," ++
            "\"proxy_rejected_connections\":{d},\"proxy_connection_limit_drops\":{d}," ++
            "\"proxy_h2_decode_failures\":{d},",
        .{
            @intFromBool(proxy_active),
            metrics.proxy_observations,
            proxy_active_connections,
            proxy_dropped_events,
            proxy_rejected_connections,
            proxy_connection_limit_drops,
            proxy_h2_decode_failures,
        },
    );
    try output.print("\"history_available\":{d},\"sqlite_open_failures\":{d}," ++
        "\"history_queries\":{d},\"history_query_failures\":{d}," ++
        "\"history_observation_resets\":{d},\"history_observation_failures\":{d}," ++
        "\"client_resyncs\":{d}," ++
        "\"history_queue_depth\":{d},\"history_queue_high_water\":{d}," ++
        "\"history_queue_dropped\":{d}," ++
        "\"sqlite_writes\":{d},\"sqlite_write_failures\":{d}," ++
        "\"sqlite_write_avg_us\":{d},\"sqlite_write_max_us\":{d}," ++
        "\"sqlite_queries\":{d},\"sqlite_query_failures\":{d}," ++
        "\"sqlite_query_avg_us\":{d},\"sqlite_query_max_us\":{d}," ++
        "\"input_write_avg_us\":{d},\"input_write_max_us\":{d}," ++
        "\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"ingest_avg_us\":{d},\"ingest_max_us\":{d}," ++
        "\"encode_avg_us\":{d},\"encode_max_us\":{d}," ++
        "\"ack_avg_us\":{d},\"ack_max_us\":{d}}}\n", .{
        @intFromBool(history_stats.available),
        history_stats.sqlite_open_failures,
        metrics.history_queries,
        metrics.history_query_failures,
        metrics.history_observation_resets,
        metrics.history_observation_failures,
        metrics.client_resyncs,
        history_stats.queued,
        history_stats.queue_high_water,
        history_stats.dropped,
        history_stats.sqlite_writes,
        history_stats.sqlite_write_failures,
        averageNs(history_stats.sqlite_write_ns, history_stats.sqlite_writes) / std.time.ns_per_us,
        history_stats.sqlite_write_max_ns / std.time.ns_per_us,
        history_stats.sqlite_queries,
        history_stats.sqlite_query_failures,
        averageNs(history_stats.sqlite_query_ns, history_stats.sqlite_queries) / std.time.ns_per_us,
        history_stats.sqlite_query_max_ns / std.time.ns_per_us,
        metrics.input_write.average() / std.time.ns_per_us,
        metrics.input_write.max_ns / std.time.ns_per_us,
        metrics.decode.average() / std.time.ns_per_us,
        metrics.decode.max_ns / std.time.ns_per_us,
        metrics.ingest.average() / std.time.ns_per_us,
        metrics.ingest.max_ns / std.time.ns_per_us,
        metrics.encode.average() / std.time.ns_per_us,
        metrics.encode.max_ns / std.time.ns_per_us,
        metrics.ack.average() / std.time.ns_per_us,
        metrics.ack.max_ns / std.time.ns_per_us,
    });
    return output.buffered();
}

pub fn averageNs(total: u64, count: u64) u64 {
    return if (count == 0) 0 else total / count;
}
