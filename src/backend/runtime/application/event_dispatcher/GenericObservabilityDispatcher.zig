const source_namespace = @import("observability.zig");
const event_sources = @import("../../event_sources.zig");
/// Binds observability event completions to one concrete Application type.
///
/// ```zig
/// const ObservabilityEvents = Dispatcher(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        /// Rearms the periodic source and admits at most one observation job.
        ///
        /// ```zig
        /// try ObservabilityEvents.handleMetricsTick(&application, result);
        /// ```
        pub fn handleMetricsTick(application: *Application, result: anyerror!void) !void {
            var coordinator = systemMetricsCoordinator(application);
            try coordinator.handle(result);
        }

        /// Publishes a complete value-owned observation before client delivery.
        /// Example: `ObservabilityEvents.handleMetricsSample(&application, sample);`.
        pub fn handleMetricsSample(application: *Application, sample: source_namespace.system_metrics_mod.Sample) void {
            application.metrics.system_sample.observe(sample.duration_ns);
            application.metrics.system_sample_last_ns = sample.captured_ns;
            var coordinator = systemMetricsCoordinator(application);
            coordinator.complete(sample.sampler);
        }

        /// Formats and schedules one telemetry sample when its sink remains
        /// available; source or formatting failures disable that sink.
        ///
        /// ```zig
        /// ObservabilityEvents.handleTelemetryTick(&application, telemetry, result);
        /// ```
        pub fn handleTelemetryTick(application: *Application, telemetry: *source_namespace.TelemetryState, result: anyerror!void) void {
            var coordinator = telemetryTickCoordinator(application, telemetry);
            coordinator.handle(result);
        }

        /// Releases one telemetry write and disables the sink when the write
        /// failed.
        ///
        /// ```zig
        /// ObservabilityEvents.handleTelemetryWritten(&application, telemetry, result);
        /// ```
        pub fn handleTelemetryWritten(application: *Application, telemetry: *source_namespace.TelemetryState, result: anyerror!void) void {
            switch (telemetry.finishWrite(result)) {
                .ready => {},
                .disable_sink => telemetry.deinit(application.io),
            }
        }

        const system_metrics_runtime_port: source_namespace.system_metrics_coordinator.RuntimePort(Application) = .{
            .rearm_tick = rearmSystemMetrics,
            .schedule = scheduleSystemMetrics,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeSystemMetricsCoordinator = source_namespace.system_metrics_coordinator.Coordinator(Application, system_metrics_runtime_port);

        fn systemMetricsCoordinator(application: *Application) RuntimeSystemMetricsCoordinator {
            return RuntimeSystemMetricsCoordinator.init(application, .{ .sampler = &application.system_metrics, .pending = &application.system_metrics_pending });
        }

        fn rearmSystemMetrics(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.waitForSystemMetrics();
        }

        fn scheduleSystemMetrics(application: *Application, sampler: source_namespace.system_metrics_mod.Sampler) !void {
            try application.select.concurrent(.metrics_sampled, source_namespace.system_metrics_mod.sampleOwned, .{ application.io, sampler });
        }

        const telemetry_tick_runtime_port: source_namespace.telemetry_tick_coordinator.RuntimePort(Application) = .{
            .available = telemetryAvailable,
            .disable = disableTelemetry,
            .schedule_tick = scheduleTelemetryTick,
            .format_sample = formatTelemetrySample,
            .schedule_write = scheduleTelemetryWrite,
        };

        const RuntimeTelemetryTickCoordinator = source_namespace.telemetry_tick_coordinator.Coordinator(Application, telemetry_tick_runtime_port);

        fn telemetryTickCoordinator(application: *Application, state: *source_namespace.TelemetryState) RuntimeTelemetryTickCoordinator {
            return RuntimeTelemetryTickCoordinator.init(application, state);
        }

        fn telemetryAvailable(_: *Application, state: *const source_namespace.TelemetryState) bool {
            return state.available();
        }

        fn disableTelemetry(application: *Application, state: *source_namespace.TelemetryState) void {
            state.deinit(application.io);
        }

        fn scheduleTelemetryTick(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.waitForTelemetry();
        }

        fn formatTelemetrySample(application: *Application, buffer: []u8) ![]const u8 {
            var attachment_stores: [source_namespace.max_clients]*const source_namespace.AttachmentStore = undefined;
            var attachment_count: usize = 0;
            var clients: source_namespace.telemetry_mod.ClientSample = .{ .count = application.clients.count };

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

            return source_namespace.formatRuntimeTelemetry(buffer, .{
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
                    .capture_started = proxy_metrics.capture_started,
                    .capture_truncated = proxy_metrics.capture_truncated,
                    .capture_skipped_quota = proxy_metrics.capture_skipped_quota,
                    .capture_dropped_queue = proxy_metrics.capture_dropped_queue,
                    .capture_decode_failed = proxy_metrics.capture_decode_failed,
                    .capture_queue_depth = proxy_metrics.queued_captures,
                    .capture_queue_high_water = proxy_metrics.capture_queue_high_water,
                },
                .heap = application.heap,
            });
        }

        fn scheduleTelemetryWrite(application: *Application, state: *source_namespace.TelemetryState, line: []const u8) !void {
            try application.select.concurrent(.telemetry_written, writeDiagnostics, .{ application.io, state, line });
        }

        fn writeDiagnostics(io: source_namespace.Io, state: *source_namespace.TelemetryState, bytes: []const u8) anyerror!void {
            try state.write(io, bytes);
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}
