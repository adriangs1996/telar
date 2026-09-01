//! Runtime-event adapters for pane output ingestion and process exit.

const std = @import("std");
const core = @import("telar-core");
const runtime_config = @import("../../../config.zig");
const pane_events = @import("../../../entrypoints/events/pane/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const pane_launcher_mod = @import("../../pane_launcher.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;

const IngestTestGate = runtime_config.IngestTestGate;
const Pane = pane_mod.Pane;
const pane_exit_coordinator = pane_events.exit;
const pane_ingest_coordinator = pane_events.ingest;
const pane_output_pipeline = pane_events.output;
const PaneIngestEvent = pane_ingest_coordinator.Completion;

/// Declares the follow-up operations required while processing pane output.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Dependencies(comptime Application: type) type {
    return struct {
        schedule_observation: *const fn (*Application, *Pane) anyerror!void,
        schedule_media: *const fn (*Application, *Pane) anyerror!void,
        schedule_response: *const fn (*Application, *Pane) anyerror!void,
    };
}

/// Binds pane output, ingestion and exit completions to one Application type.
///
/// ```zig
/// const PanePipelineEvents = Dispatcher(Application, dependencies);
/// ```
pub fn Dispatcher(comptime Application: type, comptime dependencies: Dependencies(Application)) type {
    return struct {
        /// Classifies one PTY read into observation, media and terminal-ingest
        /// work without performing slow projection work on the event-loop path.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleOutput(&application, event, ingest_gate);
        /// ```
        pub fn handleOutput(application: *Application, event: pane_launcher_mod.PaneOutputEvent, ingest_gate: ?*IngestTestGate) !void {
            var context: OutputRuntime = .{ .application = application, .ingest_gate = ingest_gate };
            var pipeline = paneOutputPipeline(&context);
            try pipeline.handle(event);
        }

        /// Commits one terminal-ingest result, refreshes attachments and rearms
        /// the pane's next PTY read.
        ///
        /// ```zig
        /// try PanePipelineEvents.handleIngested(&application, event);
        /// ```
        pub fn handleIngested(application: *Application, event: PaneIngestEvent) !void {
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
            ingest_gate: ?*IngestTestGate,
        };

        const pane_output_runtime_port: pane_output_pipeline.RuntimePort(OutputRuntime) = .{
            .schedule_observation = scheduleOutputObservation,
            .schedule_media = scheduleOutputMedia,
            .start_ingest = startOutputIngest,
            .has_outstanding_frame = paneHasOutstandingFrame,
            .collect = collectAfterOutput,
            .pump_clients = pumpAfterOutput,
        };

        const RuntimePaneOutputPipeline = pane_output_pipeline.Pipeline(OutputRuntime, pane_output_runtime_port);

        fn paneOutputPipeline(context: *OutputRuntime) RuntimePaneOutputPipeline {
            return RuntimePaneOutputPipeline.init(context, .{
                .io = context.application.io,
                .panes = &context.application.model.panes,
                .metrics = &context.application.metrics,
            });
        }

        fn scheduleOutputObservation(context: *OutputRuntime, pane: *Pane) !void {
            return dependencies.schedule_observation(context.application, pane);
        }

        fn scheduleOutputMedia(context: *OutputRuntime, pane: *Pane) !void {
            return dependencies.schedule_media(context.application, pane);
        }

        const PaneIngestTask = struct {
            ingest: pane_output_pipeline.Ingest,
            gate: ?*IngestTestGate,
        };

        fn startOutputIngest(context: *OutputRuntime, ingest: pane_output_pipeline.Ingest) !void {
            try context.application.select.concurrent(.pane_ingested, ingestPane, .{PaneIngestTask{
                .ingest = ingest,
                .gate = context.ingest_gate,
            }});
        }

        fn paneHasOutstandingFrame(context: *OutputRuntime, pane_id: schema.PaneId) bool {
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

        fn ingestPane(task: PaneIngestTask) PaneIngestEvent {
            const path = diagnostics.enter(.interactive);
            defer path.restore();

            if (task.gate) |gate| {
                gate.wait(task.ingest.io) catch |err| {
                    return .{ .pane = task.ingest.pane.key(), .result = err };
                };
            }

            var stats: pane_ingest_coordinator.Stats = .{};
            stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
                return .{ .pane = task.ingest.pane.key(), .result = err };
            };

            return .{ .pane = task.ingest.pane.key(), .result = stats };
        }

        const pane_ingest_runtime_port: pane_ingest_coordinator.RuntimePort(Application) = .{
            .schedule_observation = dependencies.schedule_observation,
            .schedule_media = dependencies.schedule_media,
            .refresh_clients = refreshPaneClients,
            .schedule_response = dependencies.schedule_response,
            .start_read = startNextPaneRead,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneIngestCoordinator = pane_ingest_coordinator.Coordinator(Application, pane_ingest_runtime_port);

        fn paneIngestCoordinator(application: *Application) RuntimePaneIngestCoordinator {
            return RuntimePaneIngestCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn refreshPaneClients(application: *Application, pane: *Pane) void {
            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane.id) orelse continue;

                _ = attachment.resizeIfNeeded() catch {
                    _ = application.detachSessionPane(client, pane.id);
                };
            }
        }

        fn startNextPaneRead(application: *Application, read: pane_ingest_coordinator.Read) !void {
            try application.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
        }

        const pane_exit_runtime_port: pane_exit_coordinator.RuntimePort(Application) = .{
            .revoke_credential = revokeExitedPaneCredential,
            .schedule_observation = dependencies.schedule_observation,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneExitCoordinator = pane_exit_coordinator.Coordinator(Application, pane_exit_runtime_port);

        fn paneExitCoordinator(application: *Application) RuntimePaneExitCoordinator {
            return RuntimePaneExitCoordinator.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn revokeExitedPaneCredential(application: *Application, pane: *Pane) void {
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

test {
    std.testing.refAllDecls(@This());
}
