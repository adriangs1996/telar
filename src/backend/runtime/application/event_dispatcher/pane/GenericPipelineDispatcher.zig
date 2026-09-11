const GenericPipelineDependencies = @import("GenericPipelineDependencies.zig").Type;
const pane_launcher_mod = @import("../../pane_launcher.zig");
const source_namespace = @import("pipeline.zig");
const core = @import("telar-core");
/// Binds pane output, ingestion and exit completions to one Application type.
///
/// ```zig
/// const PanePipelineEvents = Dispatcher(Application, dependencies);
/// ```
pub fn Type(comptime Application: type, comptime dependencies: GenericPipelineDependencies(Application)) type {
    return struct {
        /// Classifies one PTY read into observation, media and terminal-ingest
        /// work without performing slow projection work on the event-loop path.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleOutput(&application, event, ingest_gate);
        /// ```
        pub fn handleOutput(application: *Application, event: pane_launcher_mod.PaneOutputEvent, ingest_gate: ?*source_namespace.IngestTestGate) !void {
            core.echo_trace.mark(application.io, .output_dispatch);
            var context: OutputRuntime = .{ .application = application, .ingest_gate = ingest_gate };
            var pipeline = paneOutputPipeline(&context);
            try pipeline.handle(event);

            if (context.inline_ingest) |result| {
                try handleIngested(application, result);
            }
        }

        /// Commits one terminal-ingest result, refreshes attachments and rearms
        /// the pane's next PTY read.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleIngested(&application, event);
        /// ```
        pub fn handleIngested(application: *Application, event: source_namespace.PaneIngestEvent) !void {
            core.echo_trace.mark(application.io, .ingest_dispatch);
            var coordinator = paneIngestCoordinator(application);
            try coordinator.handle(event);
        }

        /// Applies one pane-process exit, revokes its proxy credential and
        /// schedules the final observation before lifecycle collection.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleExit(&application, event);
        /// ```
        pub fn handleExit(application: *Application, event: pane_launcher_mod.PaneExitEvent) !void {
            var coordinator = paneExitCoordinator(application);
            try coordinator.handle(event);
        }

        const OutputRuntime = struct {
            application: *Application,
            ingest_gate: ?*source_namespace.IngestTestGate,
            inline_ingest: ?source_namespace.PaneIngestEvent = null,
        };

        const pane_output_runtime_port: source_namespace.pane_output_pipeline.RuntimePort(OutputRuntime) = .{
            .schedule_observation = scheduleOutputObservation,
            .schedule_media = scheduleOutputMedia,
            .start_ingest = startOutputIngest,
            .has_outstanding_frame = paneHasOutstandingFrame,
            .collect = collectAfterOutput,
            .pump_clients = pumpAfterOutput,
        };

        const RuntimePaneOutputPipeline = source_namespace.pane_output_pipeline.Pipeline(OutputRuntime, pane_output_runtime_port);

        fn paneOutputPipeline(context: *OutputRuntime) RuntimePaneOutputPipeline {
            return RuntimePaneOutputPipeline.init(context, .{
                .io = context.application.io,
                .panes = &context.application.model.panes,
                .metrics = &context.application.metrics,
            });
        }

        fn scheduleOutputObservation(context: *OutputRuntime, pane: *source_namespace.Pane) !void {
            return dependencies.schedule_observation(context.application, pane);
        }

        fn scheduleOutputMedia(context: *OutputRuntime, pane: *source_namespace.Pane) !void {
            return dependencies.schedule_media(context.application, pane);
        }

        const PaneIngestTask = struct {
            ingest: source_namespace.pane_output_pipeline.Ingest,
            gate: ?*source_namespace.IngestTestGate,
        };

        fn startOutputIngest(context: *OutputRuntime, ingest: source_namespace.pane_output_pipeline.Ingest) !void {
            core.echo_trace.mark(ingest.io, .vt_queued);
            const task: PaneIngestTask = .{ .ingest = ingest, .gate = context.ingest_gate };

            if (context.ingest_gate == null and ingest.pane.canInlineOutput(ingest.bytes)) {
                context.inline_ingest = ingestPane(task);
                return;
            }

            try context.application.select.concurrent(.pane_ingested, ingestPane, .{task});
        }

        fn paneHasOutstandingFrame(context: *OutputRuntime, pane_id: source_namespace.schema.PaneId) bool {
            for (&context.application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane_id) orelse continue;

                if (attachment.outstandingFrameId() != 0) {
                    return true;
                }
            }

            return false;
        }

        fn collectAfterOutput(context: *OutputRuntime) void {
            context.application.collect();
        }

        fn pumpAfterOutput(context: *OutputRuntime) void {
            context.application.pumpAll();
        }

        fn ingestPane(task: PaneIngestTask) source_namespace.PaneIngestEvent {
            core.echo_trace.mark(task.ingest.io, .vt_start);
            defer core.echo_trace.mark(task.ingest.io, .vt_done);

            const path = source_namespace.diagnostics.enter(.interactive);
            defer path.restore();

            if (task.gate) |gate| {
                gate.wait(task.ingest.io) catch |err| {
                    return .{ .pane = task.ingest.pane.key(), .result = err };
                };
            }

            var stats: source_namespace.pane_ingest_coordinator.Stats = .{};
            stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
                return .{ .pane = task.ingest.pane.key(), .result = err };
            };

            return .{ .pane = task.ingest.pane.key(), .result = stats };
        }

        const pane_ingest_runtime_port: source_namespace.pane_ingest_coordinator.RuntimePort(Application) = .{
            .schedule_observation = dependencies.schedule_observation,
            .schedule_media = dependencies.schedule_media,
            .refresh_clients = refreshPaneClients,
            .schedule_response = dependencies.schedule_response,
            .start_read = startNextPaneRead,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneIngestCoordinator = source_namespace.pane_ingest_coordinator.Coordinator(Application, pane_ingest_runtime_port);

        fn paneIngestCoordinator(application: *Application) RuntimePaneIngestCoordinator {
            return RuntimePaneIngestCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn refreshPaneClients(application: *Application, pane: *source_namespace.Pane) void {
            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane.id) orelse continue;

                _ = attachment.resizeIfNeeded() catch {
                    _ = application.detachSessionPane(client, pane.id);
                };
            }
        }

        fn startNextPaneRead(application: *Application, read: source_namespace.pane_ingest_coordinator.Read) !void {
            try application.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
        }

        const pane_exit_runtime_port: source_namespace.pane_exit_coordinator.RuntimePort(Application) = .{
            .revoke_credential = revokeExitedPaneCredential,
            .schedule_observation = dependencies.schedule_observation,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneExitCoordinator = source_namespace.pane_exit_coordinator.Coordinator(Application, pane_exit_runtime_port);

        fn paneExitCoordinator(application: *Application) RuntimePaneExitCoordinator {
            return RuntimePaneExitCoordinator.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn revokeExitedPaneCredential(application: *Application, pane: *source_namespace.Pane) void {
            application.revokePaneCredential(pane);
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}
