//! Client observability state and its stable JSON projection.

const std = @import("std");
const core = @import("telar-core");
const client_outbox = @import("client_outbox.zig");
const kitty = @import("kitty.zig");
const pace = @import("pace.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;

pub const Metrics = struct {
    started_ns: u64,
    input_events: u64 = 0,
    input_bytes: u64 = 0,
    server_messages: u64 = 0,
    server_bytes: u64 = 0,
    graphics_messages: u64 = 0,
    graphics_bytes: u64 = 0,
    frames: u64 = 0,
    frame_cells: u64 = 0,
    frame_spans: u64 = 0,
    snapshots: u64 = 0,
    composed_panes: u64 = 0,
    composed_cells: u64 = 0,
    composed_damage_cells: u64 = 0,
    full_compositions: u64 = 0,
    flushes: u64 = 0,
    scanned_cells: u64 = 0,
    flushed_cells: u64 = 0,
    flushed_bytes: u64 = 0,
    graphics_flushed_bytes: u64 = 0,
    pane_graphics_flushed_bytes: u64 = 0,
    sidebar_graphics_flushed_bytes: u64 = 0,
    max_pending_updates: u64 = 0,
    mouse_events: u64 = 0,
    chrome_scanned_cells: u64 = 0,
    chrome_damaged_cells: u64 = 0,
    decode: diagnostics.Timing = .{},
    apply: diagnostics.Timing = .{},
    compose: diagnostics.Timing = .{},
    ack_enqueue: diagnostics.Timing = .{},
    input_enqueue: diagnostics.Timing = .{},
    flush: diagnostics.Timing = .{},
    draw_lateness: diagnostics.Timing = .{},
    paced_interval: diagnostics.Timing = .{},
};

pub const Snapshot = struct {
    theme_name: []const u8,
    active_tab: schema.TabId,
    tab_count: usize,
    focused_pane: schema.PaneId,
    pane_count: usize,
    pending_updates: usize,
    draw_pending: bool,
    outbox: *const client_outbox.Outbox,
    capabilities: *const kitty.TerminalCapabilities,
    sidebar_rendering: kitty.ResolvedSidebarRendering,
};

pub fn format(
    buffer: []u8,
    io: Io,
    metrics: *const Metrics,
    pacer: *const pace.Pacer,
    state: Snapshot,
) ![]const u8 {
    const now_ns = diagnostics.now(io);
    var writer = Io.Writer.fixed(buffer);
    try writer.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"client\"," ++
        "\"theme\":\"{s}\"," ++
        "\"active_tab\":{d},\"tab_count\":{d}," ++
        "\"focused_pane\":{d},\"pane_count\":{d},\"pending_updates\":{d}," ++
        "\"draw_pending\":{d},\"outbox_depth\":{d}," ++
        "\"outbox_high_water\":{d},\"outbox_saturated\":{d}," ++
        "\"outbox_coalesced_input\":{d},\"outbox_coalesced_resize\":{d}," ++
        "\"outbox_coalesced_ack\":{d},\"kitty_graphics\":\"{s}\"," ++
        "\"mouse_pixels\":\"{s}\",\"sidebar_renderer\":\"{s}\"," ++
        "\"cell_width_px\":{d},\"cell_height_px\":{d}," ++
        "\"input_events\":{d},\"input_bytes\":{d}," ++
        "\"server_messages\":{d},\"server_bytes\":{d},", .{
        now_ns / std.time.ns_per_ms,
        diagnostics.elapsed(metrics.started_ns, now_ns) / std.time.ns_per_ms,
        state.theme_name,
        schema.id.raw(state.active_tab),
        state.tab_count,
        schema.id.raw(state.focused_pane),
        state.pane_count,
        state.pending_updates,
        @intFromBool(state.draw_pending),
        state.outbox.len,
        state.outbox.stats.high_water,
        state.outbox.stats.saturated,
        state.outbox.stats.coalesced_input,
        state.outbox.stats.coalesced_resize,
        state.outbox.stats.coalesced_ack,
        @tagName(state.capabilities.kitty_graphics),
        @tagName(state.capabilities.mouse_pixels),
        @tagName(state.sidebar_rendering),
        state.capabilities.cell_width_px,
        state.capabilities.cell_height_px,
        metrics.input_events,
        metrics.input_bytes,
        metrics.server_messages,
        metrics.server_bytes,
    });
    try writer.print("\"graphics_messages\":{d},\"graphics_bytes\":{d}," ++
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
        "\"sidebar_graphics_flushed_bytes\":{d}," ++
        "\"decode_avg_us\":{d},\"decode_max_us\":{d}," ++
        "\"apply_avg_us\":{d},\"apply_max_us\":{d}," ++
        "\"compose_avg_us\":{d},\"compose_max_us\":{d}," ++
        "\"ack_enqueue_avg_us\":{d},\"ack_enqueue_max_us\":{d}," ++
        "\"input_enqueue_avg_us\":{d},\"input_enqueue_max_us\":{d}," ++
        "\"flush_avg_us\":{d},\"flush_max_us\":{d}," ++
        "\"draw_late_avg_us\":{d},\"draw_late_max_us\":{d}," ++
        "\"paced_interval_avg_us\":{d},\"paced_interval_max_us\":{d}}}\n", .{
        metrics.pane_graphics_flushed_bytes,                   metrics.sidebar_graphics_flushed_bytes,
        metrics.decode.average() / std.time.ns_per_us,         metrics.decode.max_ns / std.time.ns_per_us,
        metrics.apply.average() / std.time.ns_per_us,          metrics.apply.max_ns / std.time.ns_per_us,
        metrics.compose.average() / std.time.ns_per_us,        metrics.compose.max_ns / std.time.ns_per_us,
        metrics.ack_enqueue.average() / std.time.ns_per_us,    metrics.ack_enqueue.max_ns / std.time.ns_per_us,
        metrics.input_enqueue.average() / std.time.ns_per_us,  metrics.input_enqueue.max_ns / std.time.ns_per_us,
        metrics.flush.average() / std.time.ns_per_us,          metrics.flush.max_ns / std.time.ns_per_us,
        metrics.draw_lateness.average() / std.time.ns_per_us,  metrics.draw_lateness.max_ns / std.time.ns_per_us,
        metrics.paced_interval.average() / std.time.ns_per_us, metrics.paced_interval.max_ns / std.time.ns_per_us,
    });
    return buffer[0..writer.end];
}
