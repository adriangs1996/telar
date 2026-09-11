const GenericPipelineDependencies = @import("GenericPipelineDependencies.zig").Type;
const OutputCompletion = @import("../../../entrypoints/events/pane/OutputCompletion.zig");
const IngestTestGateType = @import("../../../IngestTestGate.zig");
const mark_module = @import("telar-core").mark;
const IngestCompletion = @import("../../../entrypoints/events/pane/IngestCompletion.zig");
const ExitCompletion = @import("../../../entrypoints/events/pane/ExitCompletion.zig");
const GenericOutputRuntimePort = @import("../../../entrypoints/events/pane/GenericOutputRuntimePort.zig").Type;
const GenericPipeline = @import("../../../entrypoints/events/pane/GenericPipeline.zig").Type;
const PaneType = @import("../../../../pane/Pane.zig");
const OutputIngest = @import("../../../entrypoints/events/pane/OutputIngest.zig");
const PaneIdType = @import("telar-core").PaneId;
const enter_module = @import("telar-core").enter;
const PaneIngestStats = @import("../../../../pane/PaneIngestStats.zig");
const GenericIngestRuntimePort = @import("../../../entrypoints/events/pane/GenericIngestRuntimePort.zig").Type;
const GenericIngestCoordinator = @import("../../../entrypoints/events/pane/GenericIngestCoordinator.zig").Type;
const ReadType = @import("../../../entrypoints/events/pane/Read.zig");
const pane_launcher_mod = @import("../../pane_launcher.zig");
const GenericExitRuntimePort = @import("../../../entrypoints/events/pane/GenericExitRuntimePort.zig").Type;
const GenericExitCoordinator = @import("../../../entrypoints/events/pane/GenericExitCoordinator.zig").Type;

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
        pub fn handleOutput(application: *Application, event: OutputCompletion, ingest_gate: ?*IngestTestGateType) !void {
            mark_module(application.io, .output_dispatch);
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
        pub fn handleIngested(application: *Application, event: IngestCompletion) !void {
            mark_module(application.io, .ingest_dispatch);
            var coordinator = paneIngestCoordinator(application);
            try coordinator.handle(event);
        }

        /// Applies one pane-process exit, revokes its proxy credential and
        /// schedules the final observation before lifecycle collection.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleExit(&application, event);
        /// ```
        pub fn handleExit(application: *Application, event: ExitCompletion) !void {
            var coordinator = paneExitCoordinator(application);
            try coordinator.handle(event);
        }

        const OutputRuntime = struct {
            application: *Application,
            ingest_gate: ?*IngestTestGateType,
            inline_ingest: ?IngestCompletion = null,
        };

        const pane_output_runtime_port: GenericOutputRuntimePort(OutputRuntime) = .{
            .schedule_observation = scheduleOutputObservation,
            .schedule_media = scheduleOutputMedia,
            .start_ingest = startOutputIngest,
            .has_outstanding_frame = paneHasOutstandingFrame,
            .collect = collectAfterOutput,
            .pump_clients = pumpAfterOutput,
        };

        const RuntimePaneOutputPipeline = GenericPipeline(OutputRuntime, pane_output_runtime_port);

        fn paneOutputPipeline(context: *OutputRuntime) RuntimePaneOutputPipeline {
            return RuntimePaneOutputPipeline.init(context, .{
                .io = context.application.io,
                .panes = &context.application.model.panes,
                .metrics = &context.application.metrics,
            });
        }

        fn scheduleOutputObservation(context: *OutputRuntime, pane: *PaneType) !void {
            return dependencies.schedule_observation(context.application, pane);
        }

        fn scheduleOutputMedia(context: *OutputRuntime, pane: *PaneType) !void {
            return dependencies.schedule_media(context.application, pane);
        }

        const PaneIngestTask = struct {
            ingest: OutputIngest,
            gate: ?*IngestTestGateType,
        };

        fn startOutputIngest(context: *OutputRuntime, ingest: OutputIngest) !void {
            mark_module(ingest.io, .vt_queued);
            const task: PaneIngestTask = .{ .ingest = ingest, .gate = context.ingest_gate };

            if (context.ingest_gate == null and ingest.pane.canInlineOutput(ingest.bytes)) {
                context.inline_ingest = ingestPane(task);
                return;
            }

            try context.application.select.concurrent(.pane_ingested, ingestPane, .{task});
        }

        fn paneHasOutstandingFrame(context: *OutputRuntime, pane_id: PaneIdType) bool {
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

        fn ingestPane(task: PaneIngestTask) IngestCompletion {
            mark_module(task.ingest.io, .vt_start);
            defer mark_module(task.ingest.io, .vt_done);

            const path = enter_module(.interactive);
            defer path.restore();

            if (task.gate) |gate| {
                gate.wait(task.ingest.io) catch |err| {
                    return .{ .pane = task.ingest.pane.key(), .result = err };
                };
            }

            var stats: PaneIngestStats = .{};
            stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
                return .{ .pane = task.ingest.pane.key(), .result = err };
            };

            return .{ .pane = task.ingest.pane.key(), .result = stats };
        }

        const pane_ingest_runtime_port: GenericIngestRuntimePort(Application) = .{
            .schedule_observation = dependencies.schedule_observation,
            .schedule_media = dependencies.schedule_media,
            .refresh_clients = refreshPaneClients,
            .schedule_response = dependencies.schedule_response,
            .start_read = startNextPaneRead,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneIngestCoordinator = GenericIngestCoordinator(Application, pane_ingest_runtime_port);

        fn paneIngestCoordinator(application: *Application) RuntimePaneIngestCoordinator {
            return RuntimePaneIngestCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn refreshPaneClients(application: *Application, pane: *PaneType) void {
            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane.id) orelse continue;

                _ = attachment.resizeIfNeeded() catch {
                    _ = application.detachSessionPane(client, pane.id);
                };
            }
        }

        fn startNextPaneRead(application: *Application, read: ReadType) !void {
            try application.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
        }

        const pane_exit_runtime_port: GenericExitRuntimePort(Application) = .{
            .revoke_credential = revokeExitedPaneCredential,
            .schedule_observation = dependencies.schedule_observation,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneExitCoordinator = GenericExitCoordinator(Application, pane_exit_runtime_port);

        fn paneExitCoordinator(application: *Application) RuntimePaneExitCoordinator {
            return RuntimePaneExitCoordinator.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn revokeExitedPaneCredential(application: *Application, pane: *PaneType) void {
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
