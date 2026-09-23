const SystemMetricsSample = @import("../../observability/SystemMetricsSample.zig");
const State = @import("../../observability/State.zig");
const SourcesType = @import("../../Sources.zig");
const SamplerType = @import("../../observability/Sampler.zig");
const system_metrics_module = @import("../../observability/system_metrics.zig");
const store_support = @import("../../client/store_support.zig");
const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const ClientSampleType = @import("../../observability/ClientSample.zig");
const telemetry_module = @import("../../observability/telemetry.zig");
const std = @import("std");

const RuntimeModel = @import("../../RuntimeModel.zig");

/// Rearms the periodic source and admits at most one observation job.
///
/// ```zig
/// try ObservabilityEvents.handleMetricsTick(&model, result);
/// ```
pub fn handleMetricsTick(model: *RuntimeModel, result: anyerror!void) !void {
    result catch return;
    try rearmSystemMetrics(model);
    if (model.system_metrics_pending) {
        return;
    }

    model.system_metrics_pending = true;
    errdefer model.system_metrics_pending = false;
    try scheduleSystemMetrics(model, model.system_metrics);
}

/// Publishes a complete value-owned observation before client delivery.
/// Example: `ObservabilityEvents.handleMetricsSample(&model, sample);`.
pub fn handleMetricsSample(model: *RuntimeModel, sample: SystemMetricsSample) void {
    model.metrics.system_sample.observe(sample.duration_ns);
    model.metrics.system_sample_last_ns = sample.captured_ns;
    publishMetrics(model, sample.sampler);
}

/// Formats and schedules one telemetry sample when its sink remains
/// available; source or formatting failures disable that sink.
///
/// ```zig
/// ObservabilityEvents.handleTelemetryTick(&model, telemetry, result);
/// ```
pub fn handleTelemetryTick(model: *RuntimeModel, telemetry: *State, result: anyerror!void) void {
    result catch {
        telemetry.deinit(model.io);
        return;
    };

    if (!(telemetry.available())) {
        return;
    }

    scheduleTelemetryTick(model) catch {
        telemetry.deinit(model.io);
        return;
    };

    if (telemetry.writePending()) {
        return;
    }

    const line = formatTelemetrySample(model, telemetry.buffer()) catch return;
    telemetry.beginWrite();
    scheduleTelemetryWrite(model, telemetry, line) catch {
        telemetry.cancelWrite();
        telemetry.deinit(model.io);
    };
}

/// Releases one telemetry write and disables the sink when the write
/// failed.
///
/// ```zig
/// ObservabilityEvents.handleTelemetryWritten(&model, telemetry, result);
/// ```
pub fn handleTelemetryWritten(model: *RuntimeModel, telemetry: *State, result: anyerror!void) void {
    switch (telemetry.finishWrite(result)) {
        .ready => {},
        .disable_sink => telemetry.deinit(model.io),
    }
}

fn rearmSystemMetrics(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.waitForSystemMetrics();
}

fn scheduleSystemMetrics(model: *RuntimeModel, sampler: SamplerType) !void {
    try model.select.concurrent(.metrics_sampled, system_metrics_module.sampleOwned, .{ model.io, sampler });
}

fn scheduleTelemetryTick(model: *RuntimeModel) !void {
    var sources = SourcesType.init(model.io, model.select);
    try sources.waitForTelemetry();
}

fn formatTelemetrySample(model: *RuntimeModel, buffer: []u8) ![]const u8 {
    var attachment_stores: [store_support.max_clients]*const AttachmentStoreType = undefined;
    var attachment_count: usize = 0;
    var clients: ClientSampleType = .{ .count = model.clients.count };

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        attachment_stores[attachment_count] = &session.attachments;
        attachment_count += 1;
        clients.response_queue_depth += session.delivery.responses.len;
        clients.response_queue_high_water += session.delivery.responses.high_water;
        clients.response_queue_dropped +|= session.delivery.responses.dropped;
    }

    clients.attachment_stores = attachment_stores[0..attachment_count];

    const proxy_metrics = model.resources.proxy.metrics();
    const workspaces = model.workspaceReader();

    return telemetry_module.formatRuntimeTelemetry(buffer, .{
        .io = model.io,
        .metrics = &model.metrics,
        .clients = clients,
        .workspace_count = workspaces.count(),
        .tab_count = workspaces.totalTabs(),
        .panes = &model.panes,
        .history_service = model.resources.history.service(),
        .proxy = .{
            .active = model.resources.proxy.active(),
            .active_connections = proxy_metrics.active_connections,
            .event_queue_depth = proxy_metrics.queued_events,
            .event_queue_high_water = proxy_metrics.event_queue_high_water,
            .dropped_events = proxy_metrics.dropped_events,
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
            .claude_inference_requests = proxy_metrics.claude_inference_requests,
            .claude_sse_payload_fragments = proxy_metrics.claude_sse_payload_fragments,
            .claude_turn_completions = proxy_metrics.claude_turn_completions,
            .claude_successful_responses = proxy_metrics.claude_successful_responses,
            .claude_failure_observations = proxy_metrics.claude_failure_observations,
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

fn scheduleTelemetryWrite(model: *RuntimeModel, state: *State, line: []const u8) !void {
    try model.select.concurrent(.telemetry_written, writeDiagnostics, .{ model.io, state, line });
}

fn writeDiagnostics(io: std.Io, state: *State, bytes: []const u8) anyerror!void {
    try state.write(io, bytes);
}

fn publishMetrics(model: *RuntimeModel, sampled: SamplerType) void {
    std.debug.assert(model.system_metrics_pending);
    model.system_metrics_pending = false;
    model.system_metrics = sampled;
}
