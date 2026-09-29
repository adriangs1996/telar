//! When telemetry is enabled, each tick formats one bounded latest-state
//! line about the runtime and a worker appends it to the diagnostics sink.
//! Any sink failure disables the sink; the runtime keeps running.

const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const ClientSample = @import("observability/ClientSample.zig");
const Sources = @import("Sources.zig");
const TelemetryState = @import("observability/State.zig");
const telemetry = @import("observability/telemetry.zig");

/// Rearms the tick and schedules one sample write unless one is in flight.
///
/// ```zig
/// runtime_telemetry.tick(model, &resources.telemetry, result);
/// ```
pub fn tick(model: *RuntimeModel, sink: *TelemetryState, result: anyerror!void) void {
    result catch {
        sink.deinit(model.io);
        return;
    };

    if (!sink.available()) {
        return;
    }

    var sources = Sources.init(model.io, model.select);
    sources.waitForTelemetry() catch {
        sink.deinit(model.io);
        return;
    };

    if (sink.writePending()) {
        return;
    }

    const line = format(model, sink.buffer()) catch return;
    sink.beginWrite();
    model.select.concurrent(.telemetry_written, write, .{ model.io, sink, line }) catch {
        sink.cancelWrite();
        sink.deinit(model.io);
    };
}

/// Retires one write and disables the sink when it failed.
///
/// ```zig
/// runtime_telemetry.finish(model, &resources.telemetry, result);
/// ```
pub fn finish(model: *RuntimeModel, sink: *TelemetryState, result: anyerror!void) void {
    switch (sink.finishWrite(result)) {
        .ready => {},
        .disable_sink => sink.deinit(model.io),
    }
}

fn write(io: std.Io, sink: *TelemetryState, bytes: []const u8) anyerror!void {
    try sink.write(io, bytes);
}

fn format(model: *RuntimeModel, buffer: []u8) ![]const u8 {
    var clients: ClientSample = .{
        .count = model.clients.count,
        .attachments = &model.attachments,
    };

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        clients.response_queue_depth += session.delivery.responses.len;
        clients.response_queue_high_water += session.delivery.responses.high_water;
        clients.response_queue_dropped +|= session.delivery.responses.dropped;
    }

    const proxy_metrics = model.resources.proxy.metrics();
    const workspaces = &model.workspaces;

    return telemetry.formatRuntimeTelemetry(buffer, .{
        .io = model.io,
        .metrics = &model.metrics,
        .clients = clients,
        .workspace_count = workspaces.count,
        .tab_count = workspaces.totalTabs(),
        .panes = &model.panes,
        .history_service = model.resources.history.service(),
        .proxy = .{
            .active = model.resources.proxy.active(),
            .port = model.resources.proxy.port(),
            .preferred_port = model.resources.proxy.preferredPort(),
            .active_connections = proxy_metrics.active_connections,
            .rejected_connections = proxy_metrics.rejected_connections,
            .invalid_authorization_rejections = proxy_metrics.invalid_authorization_rejections,
            .unknown_credential_rejections = proxy_metrics.unknown_credential_rejections,
            .connection_limit_drops = proxy_metrics.connection_limit_drops,
            .h2_decode_failures = proxy_metrics.h2_decode_failures,
            .passthrough_connections = proxy_metrics.passthrough_connections,
            .upstream_connect_failures = proxy_metrics.upstream_connect_failures,
            .tls_context_failures = proxy_metrics.tls_context_failures,
            .tls_upstream_handshake_failures = proxy_metrics.tls_upstream_handshake_failures,
            .tls_downstream_handshake_failures = proxy_metrics.tls_downstream_handshake_failures,
            .tls_mint_failures = proxy_metrics.tls_mint_failures,
            .capture_started = proxy_metrics.capture_started,
            .capture_truncated = proxy_metrics.capture_truncated,
            .capture_skipped_quota = proxy_metrics.capture_skipped_quota,
            .capture_dropped_queue = proxy_metrics.capture_dropped_queue,
            .capture_decode_failed = proxy_metrics.capture_decode_failed,
            .capture_queue_depth = proxy_metrics.queued_captures,
            .capture_queue_high_water = proxy_metrics.capture_queue_high_water,
        },
        .heap = &model.resources.heap,
    });
}
