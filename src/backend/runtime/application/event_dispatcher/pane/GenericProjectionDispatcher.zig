const GenericProjectionDependencies = @import("GenericProjectionDependencies.zig").Type;
const source_namespace = @import("projection.zig");
const history = @import("../../../../history/root.zig");
const agent_process = @import("../../../../process/root.zig");
const media_mod = @import("../../../../media/root.zig");
/// Binds pane observation and media completions to one Application type.
///
/// ```zig
/// const PaneProjectionEvents = Dispatcher(Application, dependencies);
/// ```
pub fn Type(comptime Application: type, comptime dependencies: GenericProjectionDependencies(Application)) type {
    return struct {
        /// Applies one process/output observation to the pane and agent
        /// aggregates, then schedules any resulting description work.
        ///
        /// ```zig
        /// try PaneProjectionEvents.handleObserved(&application, event);
        /// ```
        pub fn handleObserved(application: *Application, event: source_namespace.PaneObservationEvent) !void {
            var coordinator = paneObservationCoordinator(application);
            try coordinator.handle(event);
        }

        /// Applies one decoded media projection, synchronizes client
        /// attachments and schedules any generated terminal response.
        ///
        /// ```zig
        /// try PaneProjectionEvents.handleMedia(&application, event);
        /// ```
        pub fn handleMedia(application: *Application, event: source_namespace.PaneMediaEvent) !void {
            var coordinator = paneMediaCoordinator(application);
            try coordinator.handle(event);
        }

        /// Starts a pane observation when its single-flight state permits it.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleObservation(&application, pane);
        /// ```
        pub fn scheduleObservation(application: *Application, pane: *source_namespace.Pane) !void {
            var coordinator = paneObservationCoordinator(application);
            return coordinator.schedule(pane);
        }

        /// Starts media processing when the pane has pending media work and no
        /// media operation is already in flight.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleMedia(&application, pane);
        /// ```
        pub fn scheduleMedia(application: *Application, pane: *source_namespace.Pane) !void {
            var coordinator = paneMediaCoordinator(application);
            return coordinator.schedule(pane);
        }

        const pane_observation_runtime_port: source_namespace.pane_observation_coordinator.RuntimePort(Application) = .{
            .start = startPaneObservation,
            .publish_sound = publishObservedAgentSound,
            .schedule_description = dependencies.schedule_description,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneObservationCoordinator = source_namespace.pane_observation_coordinator.Coordinator(Application, pane_observation_runtime_port);

        fn paneObservationCoordinator(application: *Application) RuntimePaneObservationCoordinator {
            return RuntimePaneObservationCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn startPaneObservation(application: *Application, work: source_namespace.pane_observation_coordinator.Work) !void {
            try application.select.concurrent(.pane_observed, observePane, .{work});
        }

        fn observePane(work: source_namespace.pane_observation_coordinator.Work) source_namespace.PaneObservationEvent {
            const path = source_namespace.diagnostics.enter(.observation);
            defer path.restore();

            var stats: history.observer.Stats = .{};
            const process_probe = agent_process.probe(.{
                .process_group_id = work.pane.session.foregroundProcessGroup(),
                .shell_pid = work.pane.session.processId(),
                .previous = work.process_cache,
                .manifests = work.pane.manifests,
            });
            work.pane.processHistoryObservation(.{ .size = work.current_size, .provider = process_probe.cache.provider }, &stats);
            return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
        }

        fn publishObservedAgentSound(application: *Application, notification: source_namespace.schema.AgentSoundNotification) void {
            application.publishAgentSound(notification);
        }

        const pane_media_runtime_port: source_namespace.pane_media_coordinator.RuntimePort(Application) = .{
            .start = startPaneMedia,
            .enforce_quotas = enforcePaneGraphicsQuotas,
            .synchronize_clients = synchronizeMediaClients,
            .schedule_response = dependencies.schedule_response,
            .pump_clients = pumpRuntimeClients,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneMediaCoordinator = source_namespace.pane_media_coordinator.Coordinator(Application, pane_media_runtime_port);

        fn paneMediaCoordinator(application: *Application) RuntimePaneMediaCoordinator {
            return RuntimePaneMediaCoordinator.init(application, .{
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneMedia(application: *Application, work: source_namespace.pane_media_coordinator.Work) !void {
            try application.select.concurrent(.pane_media, processPaneMedia, .{work});
        }

        fn processPaneMedia(work: source_namespace.pane_media_coordinator.Work) source_namespace.PaneMediaEvent {
            const path = source_namespace.diagnostics.enter(.media);
            defer path.restore();

            var stats: media_mod.Stats = .{};
            const started = source_namespace.diagnostics.now(work.pane.io);
            work.pane.processMedia(work.current_size, &stats);
            stats.elapsed_ns = source_namespace.diagnostics.elapsed(started, source_namespace.diagnostics.now(work.pane.io));
            return .{ .pane = work.pane.key(), .stats = stats };
        }

        fn enforcePaneGraphicsQuotas(application: *Application, pane: *source_namespace.Pane) void {
            source_namespace.enforceGraphicsQuotas(application.io, pane);
        }

        fn synchronizeMediaClients(application: *Application, pane: *source_namespace.Pane, reset: bool) source_namespace.media_projection.Stats {
            var stores: [source_namespace.max_clients]*source_namespace.AttachmentStore = undefined;
            var count: usize = 0;

            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                stores[count] = &client.attachments;
                count += 1;
            }

            return source_namespace.media_projection.synchronize(pane, stores[0..count], reset);
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}
