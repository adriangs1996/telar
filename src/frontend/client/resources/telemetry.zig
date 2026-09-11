//! Client observability state and its stable JSON projection.

const FormatRequest = @import("FormatRequest.zig");
const now_module = @import("telar-core").now;
const std = @import("std");
const elapsed_module = @import("telar-core").elapsed;
const raw_module = @import("telar-core").raw;
const rssBytes_module = @import("telar-core").rssBytes;
const Client = @import("../Client.zig");
const Snapshot = @import("telar-core").SnapshotSnapshot;
const SnapshotType = @import("Snapshot.zig");
const runtime_transport = @import("../entrypoints/runtime_io.zig");
const CellType = @import("telar-core").Cell;
const waitForTick_module = @import("telar-core").waitForTick;
const TelemetryState = @import("TelemetryState.zig");
const SinkType = @import("telar-core").Sink;
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const PacerType = @import("../../presentation/Pacer.zig");
const Metrics = @import("Metrics.zig");
const enabled_module = @import("telar-core").enabled;

pub const buffer_size = 8192;

/// Projects one immutable client observation into a bounded JSON line.
///
/// ```zig
/// const line = try format(&buffer, request);
/// ```
pub fn format(buffer: []u8, request: FormatRequest) ![]const u8 {
    const metrics = request.metrics;
    const pacer = request.pacer;
    const state = request.snapshot;
    const now_ns = now_module(request.io);
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"client\"," ++
        "\"theme\":\"{s}\",\"icons\":\"{s}\"," ++
        "\"active_tab\":{d},\"tab_count\":{d}," ++
        "\"focused_pane\":{d},\"pane_count\":{d},\"pending_updates\":{d}," ++
        "\"draw_pending\":{d},\"media_pending\":{d},\"outbox_depth\":{d}," ++
        "\"outbox_high_water\":{d},\"outbox_saturated\":{d}," ++
        "\"outbox_coalesced_input\":{d},\"outbox_coalesced_resize\":{d}," ++
        "\"outbox_coalesced_ack\":{d},\"outbox_coalesced_layout\":{d}," ++
        "\"kitty_graphics\":\"{s}\"," ++
        "\"kitty_zlib\":\"{s}\"," ++
        "\"mouse_pixels\":\"{s}\",\"sidebar_renderer\":\"{s}\"," ++
        "\"cell_width_px\":{d},\"cell_height_px\":{d}," ++
        "\"input_events\":{d},\"input_bytes\":{d},\"key_lease_overflows\":{d}," ++
        "\"server_messages\":{d},\"server_bytes\":{d},", .{
        now_ns / std.time.ns_per_ms,
        elapsed_module(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        state.theme_name,
        state.icon_theme_name,
        raw_module(state.active_tab),
        state.tab_count,
        raw_module(state.focused_pane),
        state.pane_count,
        state.pending_updates,
        @intFromBool(state.draw_pending),
        @intFromBool(state.media_pending),
        state.outbox.depth,
        state.outbox.high_water,
        state.outbox.saturated,
        state.outbox.coalesced_input,
        state.outbox.coalesced_resize,
        state.outbox.coalesced_ack,
        state.outbox.coalesced_client_layout,
        @tagName(state.capabilities.images),
        @tagName(state.zlib_support),
        @tagName(state.capabilities.pointer_pixels),
        @tagName(state.sidebar_rendering),
        state.capabilities.cell_width_px,
        state.capabilities.cell_height_px,
        metrics.input_events,
        metrics.input_bytes,
        metrics.key_lease_overflows,
        metrics.server_messages,
        metrics.server_bytes,
    });
    try writer.print("\"graphics_messages\":{d},\"graphics_bytes\":{d}," ++
        "\"graphics_images\":{d},\"pane_shared_images\":{d}," ++
        "\"pane_inline_images\":{d},\"pane_compressed_images\":{d}," ++
        "\"pane_transmission_passes\":{d},\"pane_compress_passes\":{d}," ++
        "\"frames\":{d},\"frame_cells\":{d},\"frame_spans\":{d}," ++
        "\"snapshots\":{d},\"composed_panes\":{d},\"composed_cells\":{d}," ++
        "\"composed_damage_cells\":{d},\"full_compositions\":{d}," ++
        "\"flushes\":{d},\"scanned_cells\":{d},\"flushed_cells\":{d}," ++
        "\"flushed_bytes\":{d},\"graphics_flushed_bytes\":{d}," ++
        "\"max_pending_updates\":{d}," ++
        "\"mouse_events\":{d},\"chrome_scanned_cells\":{d}," ++
        "\"chrome_damaged_cells\":{d}," ++
        "\"pacer_drawn\":{d},\"pacer_throttled\":{d},\"pacer_absorbed\":{d}", .{
        metrics.graphics_messages,
        metrics.graphics_bytes,
        metrics.graphics_images,
        metrics.pane_shared_images,
        metrics.pane_inline_images,
        metrics.pane_compressed_images,
        metrics.pane_transmission_passes,
        metrics.pane_compress_passes,
        metrics.frames,
        metrics.frame_cells,
        metrics.frame_spans,
        metrics.snapshots,
        metrics.composed_panes,
        metrics.composed_cells,
        metrics.composed_damage_cells,
        metrics.full_compositions,
        metrics.flushes,
        metrics.scanned_cells,
        metrics.flushed_cells,
        metrics.flushed_bytes,
        metrics.graphics_flushed_bytes,
        metrics.max_pending_updates,
        metrics.mouse_events,
        metrics.chrome_scanned_cells,
        metrics.chrome_damaged_cells,
        pacer.stats.drawn,
        pacer.stats.throttled,
        pacer.stats.absorbed,
    });
    try writer.print(",\"pane_graphics_flushed_bytes\":{d}," ++
        "\"toast_graphics_flushed_bytes\":{d}," ++
        "\"sidebar_graphics_flushed_bytes\":{d}," ++
        "\"icon_graphics_flushed_bytes\":{d}," ++
        "\"modal_graphics_flushed_bytes\":{d}," ++
        "\"attachment_graphics_flushed_bytes\":{d},\"media_flushes\":{d}," ++
        "\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"apply_avg_us\":{d},\"apply_max_us\":{d}," ++
        "\"compose_avg_us\":{d},\"compose_max_us\":{d}," ++
        "\"ack_enqueue_avg_us\":{d},\"ack_enqueue_max_us\":{d}," ++
        "\"input_enqueue_avg_us\":{d},\"input_enqueue_max_us\":{d}," ++
        "\"flush_avg_us\":{d},\"flush_max_us\":{d}," ++
        "\"media_flush_avg_us\":{d},\"media_flush_max_us\":{d}," ++
        "\"draw_late_avg_us\":{d},\"draw_late_max_us\":{d}," ++
        "\"paced_interval_avg_us\":{d},\"paced_interval_max_us\":{d}," ++
        "\"media_deferrals\":{d}," ++
        "\"pane_present_interval_avg_us\":{d},\"pane_present_interval_max_us\":{d}," ++
        "\"shared_expiries\":{d}," ++
        "\"shared_retire_latency_avg_us\":{d},\"shared_retire_latency_max_us\":{d}", .{
        metrics.pane_graphics_flushed_bytes,                          metrics.toast_graphics_flushed_bytes,
        metrics.sidebar_graphics_flushed_bytes,                       metrics.icon_graphics_flushed_bytes,
        metrics.modal_graphics_flushed_bytes,                         metrics.attachment_graphics_flushed_bytes,
        metrics.media_flushes,                                        metrics.decode.average() / std.time.ns_per_us,
        metrics.decode.max_ns / std.time.ns_per_us,                   metrics.apply.average() / std.time.ns_per_us,
        metrics.apply.max_ns / std.time.ns_per_us,                    metrics.compose.average() / std.time.ns_per_us,
        metrics.compose.max_ns / std.time.ns_per_us,                  metrics.ack_enqueue.average() / std.time.ns_per_us,
        metrics.ack_enqueue.max_ns / std.time.ns_per_us,              metrics.input_enqueue.average() / std.time.ns_per_us,
        metrics.input_enqueue.max_ns / std.time.ns_per_us,            metrics.flush.average() / std.time.ns_per_us,
        metrics.flush.max_ns / std.time.ns_per_us,                    metrics.media_flush.average() / std.time.ns_per_us,
        metrics.media_flush.max_ns / std.time.ns_per_us,              metrics.draw_lateness.average() / std.time.ns_per_us,
        metrics.draw_lateness.max_ns / std.time.ns_per_us,            metrics.paced_interval.average() / std.time.ns_per_us,
        metrics.paced_interval.max_ns / std.time.ns_per_us,           metrics.media_deferrals,
        metrics.pane_present_interval.average() / std.time.ns_per_us, metrics.pane_present_interval.max_ns / std.time.ns_per_us,
        state.shared_expiries,                                        state.shared_retire_latency.average() / std.time.ns_per_us,
        state.shared_retire_latency.max_ns / std.time.ns_per_us,
    });
    try writer.print(",\"pill_graphics_flushed_bytes\":{d},\"pill_cache_bytes\":{d}", .{
        metrics.pill_graphics_flushed_bytes,
        state.pill_cache_bytes,
    });
    try writer.print(",\"rss_bytes\":{d},\"lua_used\":{d},\"lua_limit\":{d}," ++
        "\"kitty_store_bytes\":{d},\"toast_cache_bytes\":{d}," ++
        "\"sidebar_cache_bytes\":{d},\"icon_cache_bytes\":{d}," ++
        "\"modal_cache_bytes\":{d}," ++
        "\"attachment_cache_bytes\":{d}," ++
        "\"screen_bytes\":{d}," ++
        "\"heap_live_bytes\":{d},\"heap_live_allocs\":{d}," ++
        "\"heap_allocs\":{d},\"heap_alloc_bytes\":{d}," ++
        "\"interactive_allocs\":{d},\"interactive_alloc_bytes\":{d}," ++
        "\"media_allocs\":{d},\"media_alloc_bytes\":{d}," ++
        "\"observation_allocs\":{d},\"observation_alloc_bytes\":{d}," ++
        "\"other_allocs\":{d},\"other_alloc_bytes\":{d}}}\n", .{
        rssBytes_module(),
        state.lua_used,
        state.lua_limit,
        state.kitty_store_bytes,
        state.toast_cache_bytes,
        state.sidebar_cache_bytes,
        state.icon_cache_bytes,
        state.modal_cache_bytes,
        state.attachment_cache_bytes,
        state.screen_bytes,
        state.heap.live_bytes,
        state.heap.live_allocs,
        state.heap.allocs,
        state.heap.alloc_bytes,
        state.heap.interactive_allocs,
        state.heap.interactive_alloc_bytes,
        state.heap.media_allocs,
        state.heap.media_alloc_bytes,
        state.heap.observation_allocs,
        state.heap.observation_alloc_bytes,
        state.heap.other_allocs,
        state.heap.other_alloc_bytes,
    });
    return buffer[0..writer.end];
}

/// Schedules the first diagnostics tick when the fail-closed sink exists.
///
/// ```zig
/// try telemetry.start(client);
/// ```
pub fn start(client: *Client) !void {
    if (!client.telemetry.available()) {
        return;
    }

    try scheduleTick(client);
}

/// Rearms diagnostics and offers one latest-state write to the observation path.
///
/// ```zig
/// telemetry.handleTick(client, result, heap.snapshot());
/// ```
pub fn handleTick(client: *Client, result: anyerror!void, heap: Snapshot) void {
    result catch {
        client.telemetry.disable(client.io);
        return;
    };

    if (!client.telemetry.available()) {
        return;
    }

    scheduleTick(client) catch {
        client.telemetry.disable(client.io);
        return;
    };

    if (client.telemetry.write_pending) {
        return;
    }

    const state = capture(client, heap) orelse return;
    const line = format(&client.telemetry.buffer, .{
        .io = client.io,
        .metrics = &client.telemetry.metrics,
        .pacer = &client.presenter.pacer,
        .snapshot = state,
    }) catch return;

    if (!client.telemetry.reserveWrite()) {
        return;
    }

    client.select.concurrent(.telemetry_written, writeDiagnostics, .{
        client.io,
        &client.telemetry.sink,
        line,
    }) catch {
        client.telemetry.write_pending = false;
        client.telemetry.disable(client.io);
    };
}

/// Releases one diagnostics write and finalizes a deferred sink shutdown.
///
/// ```zig
/// telemetry.handleWritten(client, result);
/// ```
pub fn handleWritten(client: *Client, result: anyerror!void) void {
    finishWrite(&client.telemetry, client.io, result);
}

fn capture(client: *Client, heap: Snapshot) ?SnapshotType {
    const active = client.model.workspace.active() orelse return null;
    const focused = active.model.layout.focused() orelse .invalid;

    return .{
        .theme_name = client.view.theme.base.canonicalName(),
        .icon_theme_name = client.view.icon_theme.canonicalName(),
        .active_tab = active.location.tab_id,
        .tab_count = client.model.workspace.count,
        .focused_pane = focused,
        .pane_count = active.model.pane_count,
        .pending_updates = client.presenter.pending_updates,
        .draw_pending = client.presenter.draw_pending,
        .media_pending = client.presenter.media_tick_pending,
        .outbox = runtime_transport.snapshot(client),
        .capabilities = client.model.hostCapabilities(),
        .zlib_support = client.host_negotiation.zlib_support,
        .sidebar_rendering = client.view.sidebar_rendering,
        .lua_used = if (client.lua_generation) |generation| generation.vm.meter.used else 0,
        .lua_limit = if (client.lua_generation) |generation| generation.vm.meter.limit else 0,
        .kitty_store_bytes = client.graphics_store.total_bytes,
        .toast_cache_bytes = client.view.kittyToasts().retainedBytes(),
        .sidebar_cache_bytes = client.view.kittySidebar().retainedBytes(),
        .icon_cache_bytes = client.view.kittyIcons().retainedBytes(),
        .modal_cache_bytes = client.view.kittyModal().retainedBytes(),
        .pill_cache_bytes = client.view.kittyPill().retainedBytes(),
        .attachment_cache_bytes = client.view.kittyAttachments().retainedBytes(),
        .screen_bytes = (client.presenter.screen.front.cells.len +
            client.presenter.screen.back.cells.len) *
            @sizeOf(CellType),
        .shared_expiries = client.graphics_store.delivery.shared_expiries,
        .shared_retire_latency = client.graphics_store.delivery.retire_latency,
        .heap = heap,
    };
}

fn scheduleTick(client: *Client) !void {
    try client.select.concurrent(.telemetry_tick, waitForTick_module, .{client.io});
}

fn finishWrite(state: *TelemetryState, io: std.Io, result: anyerror!void) void {
    state.write_pending = false;
    result catch {
        state.enabled = false;
    };

    if (!state.enabled) {
        state.sink.deinit(io);
    }
}

fn writeDiagnostics(io: std.Io, sink: *SinkType, bytes: []const u8) anyerror!void {
    try sink.write(io, bytes);
}

test "client telemetry reports lua kitty and heap retained bytes" {
    const io = std.testing.io;
    const capabilities: HostCapabilitiesType = .{};
    const pacer: PacerType = .{};
    const metrics: Metrics = .{ .started_ns = 0, .key_lease_overflows = 3 };
    var buffer: [8192]u8 = undefined;
    const line = try format(&buffer, .{
        .io = io,
        .metrics = &metrics,
        .pacer = &pacer,
        .snapshot = .{
            .theme_name = "vesper",
            .icon_theme_name = "nerd-font",
            .active_tab = @enumFromInt(1),
            .tab_count = 1,
            .focused_pane = @enumFromInt(2),
            .pane_count = 1,
            .pending_updates = 0,
            .draw_pending = false,
            .media_pending = true,
            .outbox = .{ .coalesced_client_layout = 2 },
            .capabilities = capabilities,
            .sidebar_rendering = .cells,
            .lua_used = 123,
            .lua_limit = 1024,
            .kitty_store_bytes = 4,
            .toast_cache_bytes = 8,
            .sidebar_cache_bytes = 12,
            .icon_cache_bytes = 16,
            .modal_cache_bytes = 18,
            .attachment_cache_bytes = 20,
            .screen_bytes = 80 * 24 * 32,
            .shared_expiries = 1,
            .shared_retire_latency = .{},
            .heap = .{
                .live_bytes = 48,
                .allocs = 3,
                .interactive_allocs = 0,
                .observation_allocs = 3,
            },
        },
    });
    try std.testing.expect(std.mem.indexOf(u8, line, "\"lua_used\":123") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"lua_limit\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kitty_store_bytes\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"shared_expiries\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"media_deferrals\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"pane_present_interval_avg_us\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"shared_retire_latency_max_us\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"toast_cache_bytes\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"sidebar_cache_bytes\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"icon_cache_bytes\":16") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"attachment_cache_bytes\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"icons\":\"nerd-font\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"media_pending\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"outbox_coalesced_layout\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"key_lease_overflows\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"heap_live_bytes\":48") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"interactive_allocs\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"observation_allocs\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"rss_bytes\":") != null);
}

test "client telemetry stays disabled when no runtime endpoint exists" {
    const io = std.testing.io;
    var state = TelemetryState.init(io, "");
    defer state.deinit(io);

    try std.testing.expect(!state.enabled);
    try std.testing.expect(!state.sink.available());
}

test "client telemetry coalesces writes and defers sink shutdown until completion" {
    if (!enabled_module) {
        return;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "telemetry.log", .{});
    var state: TelemetryState = .{
        .metrics = .{ .started_ns = 0 },
        .sink = .{ .file = file },
        .enabled = true,
    };
    defer state.deinit(io);

    try std.testing.expect(state.reserveWrite());
    try std.testing.expect(!state.reserveWrite());
    state.disable(io);
    try std.testing.expect(!state.available());
    try std.testing.expect(state.sink.available());

    finishWrite(&state, io, {});
    try std.testing.expect(!state.write_pending);
    try std.testing.expect(!state.sink.available());
}

test "client telemetry write failure releases its token and disables the sink" {
    if (!enabled_module) {
        return;
    }

    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "telemetry.log", .{});
    var state: TelemetryState = .{
        .metrics = .{ .started_ns = 0 },
        .sink = .{ .file = file },
        .write_pending = true,
        .enabled = true,
    };
    defer state.deinit(io);

    finishWrite(&state, io, error.WriteFailed);
    try std.testing.expect(!state.write_pending);
    try std.testing.expect(!state.available());
    try std.testing.expect(!state.sink.available());
}
