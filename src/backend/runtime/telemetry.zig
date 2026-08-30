//! Runtime metrics and their diagnostics serialization.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const attachment_mod = @import("attachment.zig");
const history = @import("../history/root.zig");
const pane_mod = @import("../pane/root.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const AttachmentStore = attachment_mod.AttachmentStore;
const PaneStore = pane_mod.PaneStore;

pub const max_line_bytes = 12288;

pub const State = struct {
    sink: diagnostics.Sink = .{},
    line: [max_line_bytes]u8 = undefined,
    write_pending: bool = false,

    /// Creates the runtime-owned telemetry sink and its bounded line buffer.
    ///
    /// ```zig
    /// var state = State.init(io, endpoint, "runtime");
    /// ```
    pub fn init(io: Io, endpoint: []const u8, suffix: []const u8) State {
        return .{ .sink = diagnostics.Sink.init(io, endpoint, suffix) };
    }

    /// Closes the sink without invalidating an in-flight write completion.
    ///
    /// ```zig
    /// state.deinit(io);
    /// ```
    pub fn deinit(state: *State, io: Io) void {
        state.sink.deinit(io);
    }

    /// Reports whether telemetry can accept another scheduled sample.
    ///
    /// ```zig
    /// if (!state.available()) return;
    /// ```
    pub fn available(state: *const State) bool {
        return state.sink.available();
    }

    /// Returns the fixed storage reused by consecutive telemetry samples.
    ///
    /// ```zig
    /// const line = try formatRuntimeTelemetry(state.buffer(), sample);
    /// ```
    pub fn buffer(state: *State) []u8 {
        return &state.line;
    }

    /// Reports whether the shared line buffer belongs to a write actor.
    ///
    /// ```zig
    /// if (state.writePending()) return;
    /// ```
    pub fn writePending(state: *const State) bool {
        return state.write_pending;
    }

    /// Borrows the shared line buffer for one asynchronous sink write.
    ///
    /// ```zig
    /// state.beginWrite();
    /// ```
    pub fn beginWrite(state: *State) void {
        std.debug.assert(!state.write_pending);
        state.write_pending = true;
    }

    /// Rolls back a write actor that could not be scheduled.
    ///
    /// ```zig
    /// state.cancelWrite();
    /// ```
    pub fn cancelWrite(state: *State) void {
        std.debug.assert(state.write_pending);
        state.write_pending = false;
    }

    /// Releases the shared line buffer after its write actor completes.
    ///
    /// ```zig
    /// state.completeWrite();
    /// ```
    pub fn completeWrite(state: *State) void {
        std.debug.assert(state.write_pending);
        state.write_pending = false;
    }

    /// Writes the borrowed line through the development diagnostics sink.
    ///
    /// ```zig
    /// try state.write(io, line);
    /// ```
    pub fn write(state: *State, io: Io, line: []const u8) !void {
        std.debug.assert(state.write_pending);
        try state.sink.write(io, line);
    }
};

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
    /// Image transfers whose metadata crossed the transport: the runtime's
    /// delivered-images counter, so throughput needs no bytes-per-message
    /// heuristics.
    graphics_images_sent: u64 = 0,
    graphics_placements_sent: u64 = 0,
    /// Transfers frozen eagerly at a media-idle boundary rather than by the
    /// send loop catching one.
    graphics_transfers_staged: u64 = 0,
    media_bytes: u64 = 0,
    media_discarded_frames: u64 = 0,
    /// Shared frames dropped with no replacement ingested: the pane kept a
    /// stale image for that batch. Sustained growth is a frozen picture.
    media_unavailable_frames: u64 = 0,
    /// Shared frames fed to the media terminal. Moving while the graphics
    /// revision stays still isolates a silent emulator load failure.
    media_forwarded_frames: u64 = 0,
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
    agent_process_inspections: u64 = 0,
    agent_process_misses: u64 = 0,
    proxy_observations: u64 = 0,
    client_resyncs: u64 = 0,
};

pub const ClientSample = struct {
    attachment_stores: []const *const AttachmentStore = &.{},
    count: usize = 0,
    response_queue_depth: usize = 0,
    response_queue_high_water: usize = 0,
    response_queue_dropped: u64 = 0,
};

pub const ProxySample = struct {
    active: bool = false,
    active_connections: u32 = 0,
    event_queue_depth: u64 = 0,
    event_queue_high_water: u64 = 0,
    dropped_events: u64 = 0,
    rejected_connections: u64 = 0,
    invalid_authorization_rejections: u64 = 0,
    unknown_credential_rejections: u64 = 0,
    connection_limit_drops: u64 = 0,
    h2_decode_failures: u64 = 0,
    passthrough_connections: u64 = 0,
    upstream_connect_failures: u64 = 0,
    tls_context_failures: u64 = 0,
    tls_upstream_handshake_failures: u64 = 0,
    tls_downstream_handshake_failures: u64 = 0,
    tls_mint_failures: u64 = 0,
};

pub const Sample = struct {
    io: Io,
    metrics: *const RuntimeMetrics,
    clients: ClientSample = .{},
    workspace_count: usize = 0,
    tab_count: usize = 0,
    panes: *const PaneStore,
    history_service: *const history.Service,
    proxy: ProxySample = .{},
    heap: *const diagnostics.Heap,
};

/// Serializes one immutable view of runtime counters and retained resources
/// into caller-owned storage. The returned slice aliases `buffer`.
///
/// ```zig
/// const line = try formatRuntimeTelemetry(&buffer, sample);
/// ```
pub fn formatRuntimeTelemetry(buffer: []u8, sample: Sample) ![]const u8 {
    const metrics = sample.metrics;
    const panes = sample.panes;
    const clients = sample.clients;
    const proxy = sample.proxy;
    const now_ns = diagnostics.now(sample.io);
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
    var media_queue_event_high_water: usize = 0;
    var media_queue_byte_high_water: usize = 0;
    var media_dropped_events: u64 = 0;
    var media_dropped_bytes: u64 = 0;
    var pty_response_queue_depth: usize = 0;
    var pty_response_dropped: u64 = 0;
    var pane_input_queue_depth: usize = 0;
    var pane_input_dropped_bytes: u64 = 0;
    var history_input_dropped: u64 = 0;
    var pane_media_used: usize = 0;
    var vt_scrollback_bytes: usize = 0;
    var vt_screen_bytes: usize = 0;
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
        media_queue_event_high_water +|= pane.media.queue_event_high_water;
        media_queue_byte_high_water +|= pane.media.queue_byte_high_water;
        pane_media_used += pane.media_allocator.used;
        vt_scrollback_bytes += pane.vtScrollbackBytes();
        vt_screen_bytes += pane.vtScreenBytes();
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
    for (clients.attachment_stores) |attachments| {
        attachment_count += attachments.len();
        var iterator = attachments.iterator();
        while (iterator.next()) |active| {
            if (active.pane.ingest_pending) continue;
            const transfer_bytes = active.graphicsTransferBytes();
            graphics_transfer_bytes += transfer_bytes;
            graphics_resident_bytes += transfer_bytes;
            if (active.outstandingFrameId() != 0) outstanding_frames += 1;
        }
    }
    const history_stats = sample.history_service.statsSnapshot();
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
        clients.count,
        sample.workspace_count,
        sample.tab_count,
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
            "\"graphics_images_sent\":{d},\"graphics_placements_sent\":{d}," ++
            "\"graphics_transfers_staged\":{d}," ++
            "\"media_bytes\":{d},\"media_discarded_frames\":{d}," ++
            "\"media_unavailable_frames\":{d},\"media_forwarded_frames\":{d}," ++
            "\"media_resets\":{d},\"media_failures\":{d}," ++
            "\"media_queue_events\":{d},\"media_queue_bytes\":{d}," ++
            "\"media_queue_event_high_water\":{d}," ++
            "\"media_queue_byte_high_water\":{d}," ++
            "\"media_dropped_events\":{d},\"media_dropped_bytes\":{d}," ++
            "\"graphics_images\":{d},\"graphics_placements\":{d}," ++
            "\"graphics_resident_bytes\":{d},\"graphics_transfer_bytes\":{d}," ++
            "\"graphics_loading_bytes\":{d}," ++
            "\"pty_response_queue_depth\":{d},\"pty_response_dropped\":{d}," ++
            "\"pane_input_queue_depth\":{d},\"pane_input_dropped_bytes\":{d}," ++
            "\"response_queue_depth\":{d},\"response_queue_high_water\":{d}," ++
            "\"response_queue_dropped\":{d},",
        .{
            metrics.graphics_messages,
            metrics.graphics_bytes,
            metrics.graphics_images_sent,
            metrics.graphics_placements_sent,
            metrics.graphics_transfers_staged,
            metrics.media_bytes,
            metrics.media_discarded_frames,
            metrics.media_unavailable_frames,
            metrics.media_forwarded_frames,
            metrics.media_resets,
            metrics.media_failures,
            media_queue_events,
            media_queue_bytes,
            media_queue_event_high_water,
            media_queue_byte_high_water,
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
            clients.response_queue_depth,
            clients.response_queue_high_water,
            clients.response_queue_dropped,
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
        "\"agent_process_inspections\":{d},\"agent_process_misses\":{d}," ++
            "\"proxy_active\":{d},\"proxy_observations\":{d}," ++
            "\"proxy_active_connections\":{d}," ++
            "\"proxy_event_queue_depth\":{d}," ++
            "\"proxy_event_queue_high_water\":{d}," ++
            "\"proxy_dropped_events\":{d}," ++
            "\"proxy_rejected_connections\":{d}," ++
            "\"proxy_invalid_authorization_rejections\":{d}," ++
            "\"proxy_unknown_credential_rejections\":{d}," ++
            "\"proxy_connection_limit_drops\":{d}," ++
            "\"proxy_h2_decode_failures\":{d}," ++
            "\"proxy_passthrough_connections\":{d}," ++
            "\"proxy_upstream_connect_failures\":{d}," ++
            "\"proxy_tls_context_failures\":{d}," ++
            "\"proxy_tls_upstream_handshake_failures\":{d}," ++
            "\"proxy_tls_downstream_handshake_failures\":{d}," ++
            "\"proxy_tls_mint_failures\":{d},",
        .{
            metrics.agent_process_inspections,
            metrics.agent_process_misses,
            @intFromBool(proxy.active),
            metrics.proxy_observations,
            proxy.active_connections,
            proxy.event_queue_depth,
            proxy.event_queue_high_water,
            proxy.dropped_events,
            proxy.rejected_connections,
            proxy.invalid_authorization_rejections,
            proxy.unknown_credential_rejections,
            proxy.connection_limit_drops,
            proxy.h2_decode_failures,
            proxy.passthrough_connections,
            proxy.upstream_connect_failures,
            proxy.tls_context_failures,
            proxy.tls_upstream_handshake_failures,
            proxy.tls_downstream_handshake_failures,
            proxy.tls_mint_failures,
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
        "\"ack_avg_us\":{d},\"ack_max_us\":{d},", .{
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
    const heap_snap = sample.heap.snapshot();
    try output.print(
        "\"rss_bytes\":{d},\"graphics_budget_used\":{d},\"pane_media_used\":{d}," ++
            "\"vt_scrollback_bytes\":{d},\"vt_screen_bytes\":{d}," ++
            "\"history_sqlite_bytes\":{d}," ++
            "\"heap_live_bytes\":{d},\"heap_live_allocs\":{d}," ++
            "\"heap_allocs\":{d},\"heap_alloc_bytes\":{d}," ++
            "\"interactive_allocs\":{d},\"interactive_alloc_bytes\":{d}," ++
            "\"interactive_vt_allocs\":{d},\"interactive_vt_alloc_bytes\":{d}," ++
            "\"interactive_telar_allocs\":{d},\"interactive_telar_alloc_bytes\":{d}," ++
            "\"media_allocs\":{d},\"media_alloc_bytes\":{d}," ++
            "\"observation_allocs\":{d},\"observation_alloc_bytes\":{d}," ++
            "\"other_allocs\":{d},\"other_alloc_bytes\":{d}}}\n",
        .{
            diagnostics.rssBytes(),
            panes.graphics_budget.used,
            pane_media_used,
            vt_scrollback_bytes,
            vt_screen_bytes,
            sample.history_service.sqliteBytes(sample.io),
            heap_snap.live_bytes,
            heap_snap.live_allocs,
            heap_snap.allocs,
            heap_snap.alloc_bytes,
            heap_snap.interactive_allocs,
            heap_snap.interactive_alloc_bytes,
            heap_snap.interactive_vt_allocs,
            heap_snap.interactive_vt_alloc_bytes,
            heap_snap.interactive_allocs -| heap_snap.interactive_vt_allocs,
            heap_snap.interactive_alloc_bytes -| heap_snap.interactive_vt_alloc_bytes,
            heap_snap.media_allocs,
            heap_snap.media_alloc_bytes,
            heap_snap.observation_allocs,
            heap_snap.observation_alloc_bytes,
            heap_snap.other_allocs,
            heap_snap.other_alloc_bytes,
        },
    );
    return output.buffered();
}

pub fn averageNs(total: u64, count: u64) u64 {
    return if (count == 0) 0 else total / count;
}

test "telemetry state lends its line buffer to exactly one write" {
    var state: State = .{};

    try std.testing.expect(!state.writePending());
    state.beginWrite();
    try std.testing.expect(state.writePending());

    state.completeWrite();
    try std.testing.expect(!state.writePending());

    state.beginWrite();
    state.cancelWrite();
    try std.testing.expect(!state.writePending());
}

test "runtime telemetry reports retained memory domains" {
    const io = std.testing.io;
    var service = try history.Service.init(std.testing.allocator, ":memory:");
    defer service.deinit(io);
    var heap = diagnostics.Heap.init(std.testing.allocator);
    {
        const path = diagnostics.enter(.observation);
        defer path.restore();
        const scratch = try heap.allocator().alloc(u8, 16);
        defer heap.allocator().free(scratch);
        var panes: PaneStore = .{};
        panes.graphics_budget.used = 99;
        var buffer: [max_line_bytes]u8 = undefined;
        const metrics: RuntimeMetrics = .{ .started_ns = 0 };
        const line = try formatRuntimeTelemetry(&buffer, .{
            .io = io,
            .metrics = &metrics,
            .clients = .{
                .count = 2,
                .response_queue_depth = 3,
                .response_queue_high_water = 5,
                .response_queue_dropped = 7,
            },
            .workspace_count = 11,
            .tab_count = 13,
            .panes = &panes,
            .history_service = &service,
            .proxy = .{
                .active = true,
                .active_connections = 17,
                .event_queue_depth = 19,
                .event_queue_high_water = 23,
                .dropped_events = 29,
                .rejected_connections = 31,
                .invalid_authorization_rejections = 37,
                .unknown_credential_rejections = 41,
                .connection_limit_drops = 43,
                .h2_decode_failures = 47,
                .passthrough_connections = 53,
                .upstream_connect_failures = 59,
                .tls_context_failures = 61,
                .tls_upstream_handshake_failures = 67,
                .tls_downstream_handshake_failures = 71,
                .tls_mint_failures = 73,
            },
            .heap = &heap,
        });
        try std.testing.expect(std.mem.indexOf(u8, line, "\"graphics_budget_used\":99") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"pane_media_used\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"vt_scrollback_bytes\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"history_sqlite_bytes\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"rss_bytes\":") != null);
        const expected_heap = if (diagnostics.enabled)
            "\"heap_live_bytes\":16"
        else
            "\"heap_live_bytes\":0";
        const expected_observation_allocs = if (diagnostics.enabled)
            "\"observation_allocs\":1"
        else
            "\"observation_allocs\":0";

        try std.testing.expect(std.mem.indexOf(u8, line, expected_heap) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, expected_observation_allocs) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"interactive_allocs\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"interactive_vt_allocs\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"interactive_telar_allocs\":0") != null);
        const expected_fields = [_][]const u8{
            "\"client_count\":2",
            "\"workspace_count\":11",
            "\"tab_count\":13",
            "\"response_queue_depth\":3",
            "\"response_queue_high_water\":5",
            "\"response_queue_dropped\":7",
            "\"proxy_active\":1",
            "\"proxy_active_connections\":17",
            "\"proxy_event_queue_depth\":19",
            "\"proxy_event_queue_high_water\":23",
            "\"proxy_dropped_events\":29",
            "\"proxy_rejected_connections\":31",
            "\"proxy_invalid_authorization_rejections\":37",
            "\"proxy_unknown_credential_rejections\":41",
            "\"proxy_connection_limit_drops\":43",
            "\"proxy_h2_decode_failures\":47",
            "\"proxy_passthrough_connections\":53",
            "\"proxy_upstream_connect_failures\":59",
            "\"proxy_tls_context_failures\":61",
            "\"proxy_tls_upstream_handshake_failures\":67",
            "\"proxy_tls_downstream_handshake_failures\":71",
            "\"proxy_tls_mint_failures\":73",
        };

        for (expected_fields) |field| {
            try std.testing.expect(std.mem.indexOf(u8, line, field) != null);
        }
    }
}
