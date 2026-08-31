//! Runtime-event adapters for metrics sampling and telemetry delivery.

const std = @import("std");
const attachment_mod = @import("../../attachment/root.zig");
const client_store = @import("../../client/root.zig").store;
const event_sources = @import("../../event_sources.zig");
const observability = @import("../../observability/root.zig");

const Io = std.Io;

const AttachmentStore = attachment_mod.AttachmentStore;
const TelemetryState = observability.telemetry.State;
const formatRuntimeTelemetry = observability.telemetry.formatRuntimeTelemetry;
const max_clients = client_store.max_clients;
const system_metrics_mod = observability.system_metrics;
const system_metrics_coordinator = observability.system_metrics_coordinator;
const telemetry_mod = observability.telemetry;
const telemetry_tick_coordinator = observability.telemetry_tick_coordinator;

/// Binds observability event completions to one concrete Application type.
///
/// ```zig
/// const ObservabilityEvents = Dispatcher(Application);
/// ```
pub fn Dispatcher(comptime Application: type) type {
    return struct {
        /// Samples host metrics, rearms the periodic source and publishes the
        /// resulting projection to connected clients.
        ///
        /// ```zig
        /// try ObservabilityEvents.handleMetricsTick(&application, result);
        /// ```
        pub fn handleMetricsTick(application: *Application, result: anyerror!void) !void {
            var coordinator = systemMetricsCoordinator(application);
            try coordinator.handle(result);
        }

        /// Formats and schedules one telemetry sample when its sink remains
        /// available; source or formatting failures disable that sink.
        ///
        /// ```zig
        /// ObservabilityEvents.handleTelemetryTick(&application, telemetry, result);
        /// ```
        pub fn handleTelemetryTick(application: *Application, telemetry: *TelemetryState, result: anyerror!void) void {
            var coordinator = telemetryTickCoordinator(application, telemetry);
            coordinator.handle(result);
        }

        /// Releases one telemetry write and disables the sink when the write
        /// failed.
        ///
        /// ```zig
        /// ObservabilityEvents.handleTelemetryWritten(&application, telemetry, result);
        /// ```
        pub fn handleTelemetryWritten(application: *Application, telemetry: *TelemetryState, result: anyerror!void) void {
            switch (telemetry.finishWrite(result)) {
                .ready => {},
                .disable_sink => telemetry.deinit(application.io),
            }
        }

        const system_metrics_runtime_port: system_metrics_coordinator.RuntimePort(Application) = .{
            .rearm_tick = rearmSystemMetrics,
            .sample = sampleSystemMetrics,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeSystemMetricsCoordinator = system_metrics_coordinator.Coordinator(Application, system_metrics_runtime_port);

        fn systemMetricsCoordinator(application: *Application) RuntimeSystemMetricsCoordinator {
            return RuntimeSystemMetricsCoordinator.init(application, .{ .sampler = &application.system_metrics });
        }

        fn rearmSystemMetrics(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.waitForSystemMetrics();
        }

        fn sampleSystemMetrics(_: *Application, sampler: *system_metrics_mod.Sampler) void {
            sampler.sample();
        }

        const telemetry_tick_runtime_port: telemetry_tick_coordinator.RuntimePort(Application) = .{
            .available = telemetryAvailable,
            .disable = disableTelemetry,
            .schedule_tick = scheduleTelemetryTick,
            .format_sample = formatTelemetrySample,
            .schedule_write = scheduleTelemetryWrite,
        };

        const RuntimeTelemetryTickCoordinator = telemetry_tick_coordinator.Coordinator(Application, telemetry_tick_runtime_port);

        fn telemetryTickCoordinator(application: *Application, state: *TelemetryState) RuntimeTelemetryTickCoordinator {
            return RuntimeTelemetryTickCoordinator.init(application, state);
        }

        fn telemetryAvailable(_: *Application, state: *const TelemetryState) bool {
            return state.available();
        }

        fn disableTelemetry(application: *Application, state: *TelemetryState) void {
            state.deinit(application.io);
        }

        fn scheduleTelemetryTick(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.waitForTelemetry();
        }

        fn formatTelemetrySample(application: *Application, buffer: []u8) ![]const u8 {
            var attachment_stores: [max_clients]*const AttachmentStore = undefined;
            var attachment_count: usize = 0;
            var clients: telemetry_mod.ClientSample = .{ .count = application.clients.count };

            for (&application.clients.items) |*slot| {
                const session = slot.* orelse continue;
                attachment_stores[attachment_count] = &session.attachments;
                attachment_count += 1;
                clients.response_queue_depth += session.delivery.responses.len;
                clients.response_queue_high_water += session.delivery.responses.high_water;
                clients.response_queue_dropped +|= session.delivery.responses.dropped;
            }

            clients.attachment_stores = attachment_stores[0..attachment_count];

            const proxy_metrics = application.proxy_runtime.metrics();
            const workspaces = application.workspaceReader();

            return formatRuntimeTelemetry(buffer, .{
                .io = application.io,
                .metrics = &application.metrics,
                .clients = clients,
                .workspace_count = workspaces.count(),
                .tab_count = workspaces.totalTabs(),
                .panes = &application.model.panes,
                .history_service = application.history_service,
                .proxy = .{
                    .active = application.proxy_runtime.active(),
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
                },
                .heap = application.heap,
            });
        }

        fn scheduleTelemetryWrite(application: *Application, state: *TelemetryState, line: []const u8) !void {
            try application.select.concurrent(.telemetry_written, writeDiagnostics, .{ application.io, state, line });
        }

        fn writeDiagnostics(io: Io, state: *TelemetryState, bytes: []const u8) anyerror!void {
            try state.write(io, bytes);
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
