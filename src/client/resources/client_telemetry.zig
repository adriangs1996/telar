//! Client telemetry (docs/flows/client-telemetry.md): in builds with
//! diagnostics, once a second the client projects its counters and its
//! disposable state into one bounded JSON line and a worker appends it to
//! `<endpoint>.client-<pid>.log`. It observes the client; it never commits
//! semantic state, requests a draw or enters the interactive path.
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Client = @import("../execution/Client.zig");
const Metrics = @import("Metrics.zig");
const TelemetryState = @import("TelemetryState.zig");

/// Arms the first tick when the fail-closed sink exists.
/// Example: `try client_telemetry.start(client);`
pub fn start(client: *Client) !void {
    if (!client.telemetry.available()) {
        return;
    }

    try client.to_workers.push(.telemetry_tick);
}

/// Rearms the tick, then offers one latest-state line to the sink. A tick
/// that finds a write in flight folds into the next one.
/// Example: `try client_telemetry.finishTick(client, result);`
pub fn finishTick(client: *Client, result: anyerror!void) !void {
    const telemetry = &client.telemetry;
    result catch {
        telemetry.disable(client.io);
        return;
    };

    if (!telemetry.available()) {
        return;
    }

    client.to_workers.push(.telemetry_tick) catch {
        telemetry.disable(client.io);
        return;
    };

    if (telemetry.write_pending) {
        return;
    }

    const line = format(&telemetry.buffer, .{
        .now_ns = core.now(client.io),
        .metrics = &telemetry.metrics,
        .state = capture(client),
    }) catch return;

    if (!telemetry.reserveWrite()) {
        return;
    }

    telemetry.line_len = line.len;
    client.to_workers.push(.{ .telemetry_write = telemetry }) catch {
        telemetry.finishWrite(client.io, error.QueueFull);
    };
}

/// Releases the write and finishes a sink shutdown it deferred.
/// Example: `client_telemetry.finishWrite(client, result);`
pub fn finishWrite(client: *Client, result: anyerror!void) void {
    client.telemetry.finishWrite(client.io, result);
}

/// Projects one client observation into a bounded JSON line.
/// Example: `const line = try client_telemetry.format(&buffer, request);`
pub fn format(buffer: []u8, request: FormatRequest) ![]const u8 {
    const metrics = request.metrics;
    const state = request.state;
    var writer = std.Io.Writer.fixed(buffer);
    try writer.print("{{\"ts_ms\":{d},\"uptime_ms\":{d},\"role\":\"client\"," ++
        "\"theme\":\"{s}\",\"icons\":\"{s}\"," ++
        "\"active_tab\":{d},\"tab_count\":{d},\"focused_pane\":{d},\"pane_count\":{d}," ++
        "\"outbox_depth\":{d},\"outbox_high_water\":{d},\"outbox_saturated\":{d}," ++
        "\"outbox_coalesced_input\":{d},\"outbox_coalesced_resize\":{d}," ++
        "\"outbox_coalesced_ack\":{d},\"outbox_coalesced_layout\":{d}," ++
        "\"cell_width_px\":{d},\"cell_height_px\":{d},", .{
        request.now_ns / std.time.ns_per_ms,
        core.elapsed(metrics.started_ns, request.now_ns) / std.time.ns_per_ms,
        state.theme_name,
        state.icon_theme_name,
        core.raw(state.active_tab),
        state.tab_count,
        core.raw(state.focused_pane),
        state.pane_count,
        state.outbox.depth,
        state.outbox.high_water,
        state.outbox.saturated,
        state.outbox.coalesced_input,
        state.outbox.coalesced_resize,
        state.outbox.coalesced_ack,
        state.outbox.coalesced_client_layout,
        state.cell_width_px,
        state.cell_height_px,
    });
    try writer.print("\"input_events\":{d},\"input_bytes\":{d},\"key_lease_overflows\":{d},\"mouse_events\":{d}," ++
        "\"server_messages\":{d},\"server_bytes\":{d},\"graphics_messages\":{d},\"graphics_bytes\":{d}," ++
        "\"graphics_images\":{d},\"frames\":{d},\"frame_cells\":{d},\"frame_spans\":{d},\"snapshots\":{d}," ++
        "\"decode_avg_us\":{d},\"decode_max_us\":{d},\"apply_avg_us\":{d},\"apply_max_us\":{d}," ++
        "\"input_enqueue_avg_us\":{d},\"input_enqueue_max_us\":{d}," ++
        "\"rss_bytes\":{d},\"lua_used\":{d},\"lua_limit\":{d}}}\n", .{
        metrics.input_events,
        metrics.input_bytes,
        metrics.key_lease_overflows,
        metrics.mouse_events,
        metrics.server_messages,
        metrics.server_bytes,
        metrics.graphics_messages,
        metrics.graphics_bytes,
        metrics.graphics_images,
        metrics.frames,
        metrics.frame_cells,
        metrics.frame_spans,
        metrics.snapshots,
        metrics.decode.average() / std.time.ns_per_us,
        metrics.decode.max_ns / std.time.ns_per_us,
        metrics.apply.average() / std.time.ns_per_us,
        metrics.apply.max_ns / std.time.ns_per_us,
        metrics.input_enqueue.average() / std.time.ns_per_us,
        metrics.input_enqueue.max_ns / std.time.ns_per_us,
        core.rssBytes(),
        state.lua_used,
        state.lua_limit,
    });
    return writer.buffered();
}

fn capture(client: *const Client) Snapshot {
    const model = &client.model;
    const active = model.tabs.activeSlot();
    const generation = client.lua_generation;
    return .{
        .theme_name = model.theme.base.canonicalName(),
        .icon_theme_name = model.icon_theme.canonicalName(),
        .active_tab = if (active) |slot| model.tabs.location[slot].tab_id else .invalid,
        .tab_count = model.tabs.count,
        .focused_pane = if (active) |slot| model.tabs.layout[slot].focused() orelse .invalid else .invalid,
        .pane_count = if (active) |slot| model.panes.countIn(model.tabs.location[slot].tab_id) else 0,
        .outbox = model.to_runtime.snapshot(),
        .cell_width_px = model.host.host_size.cell_width_px,
        .cell_height_px = model.host.host_size.cell_height_px,
        .lua_used = if (generation) |value| value.vm.meter.used else 0,
        .lua_limit = if (generation) |value| value.vm.meter.limit else 0,
    };
}

const FormatRequest = struct {
    now_ns: u64,
    metrics: *const Metrics,
    state: Snapshot,
};

/// The client state one line reports, copied before formatting.
const Snapshot = struct {
    theme_name: []const u8,
    icon_theme_name: []const u8,
    active_tab: core.TabId,
    tab_count: usize,
    focused_pane: core.PaneId,
    pane_count: usize,
    outbox: data.OutboxSnapshot,
    cell_width_px: u16,
    cell_height_px: u16,
    lua_used: usize,
    lua_limit: usize,
};

test "a telemetry line reports the counters and the client state" {
    const metrics: Metrics = .{
        .started_ns = 0,
        .key_lease_overflows = 3,
        .frames = 5,
    };
    var buffer: [TelemetryState.buffer_size]u8 = undefined;
    const line = try format(&buffer, .{
        .now_ns = 2 * std.time.ns_per_s,
        .metrics = &metrics,
        .state = .{
            .theme_name = "vesper",
            .icon_theme_name = "nerd-font",
            .active_tab = @enumFromInt(1),
            .tab_count = 1,
            .focused_pane = @enumFromInt(2),
            .pane_count = 1,
            .outbox = .{ .coalesced_client_layout = 2 },
            .cell_width_px = 9,
            .cell_height_px = 18,
            .lua_used = 123,
            .lua_limit = 1024,
        },
    });

    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"uptime_ms\":2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"icons\":\"nerd-font\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"outbox_coalesced_layout\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"key_lease_overflows\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"frames\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"lua_limit\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"rss_bytes\":") != null);
}
