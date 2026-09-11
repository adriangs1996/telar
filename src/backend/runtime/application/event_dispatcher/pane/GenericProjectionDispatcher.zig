const GenericProjectionDependencies = @import("GenericProjectionDependencies.zig").Type;
const ObservationCompletion = @import("../../../entrypoints/events/pane/ObservationCompletion.zig");
const MediaCompletion = @import("../../../entrypoints/events/pane/MediaCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const GenericObservationRuntimePort = @import("../../../entrypoints/events/pane/GenericObservationRuntimePort.zig").Type;
const GenericObservationCoordinator = @import("../../../entrypoints/events/pane/GenericObservationCoordinator.zig").Type;
const ObservationWork = @import("../../../entrypoints/events/pane/ObservationWork.zig");
const enter_module = @import("telar-core").enter;
const StatsType = @import("../../../../history/Stats.zig");
const agent_process = @import("../../../../process/process.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;
const GenericMediaRuntimePort = @import("../../../entrypoints/events/pane/GenericMediaRuntimePort.zig").Type;
const GenericMediaCoordinator = @import("../../../entrypoints/events/pane/GenericMediaCoordinator.zig").Type;
const MediaWork = @import("../../../entrypoints/events/pane/MediaWork.zig");
const MediaStats = @import("../../../../media/Stats.zig");
const now_module = @import("telar-core").now;
const elapsed_module = @import("telar-core").elapsed;
const root = @import("../../../attachment/attachment_namespace.zig");
const PaneStats = @import("../../../entrypoints/events/pane/Stats.zig");
const store_support = @import("../../../client/store_support.zig");
const AttachmentStoreType = @import("../../../attachment/AttachmentStore.zig");
const media_projection_module = @import("../../../entrypoints/events/pane/media_projection.zig");

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
        pub fn handleObserved(application: *Application, event: ObservationCompletion) !void {
            var coordinator = paneObservationCoordinator(application);
            try coordinator.handle(event);
        }

        /// Applies one decoded media projection, synchronizes client
        /// attachments and schedules any generated terminal response.
        ///
        /// ```zig
        /// try PaneProjectionEvents.handleMedia(&application, event);
        /// ```
        pub fn handleMedia(application: *Application, event: MediaCompletion) !void {
            var coordinator = paneMediaCoordinator(application);
            try coordinator.handle(event);
        }

        /// Starts a pane observation when its single-flight state permits it.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleObservation(&application, pane);
        /// ```
        pub fn scheduleObservation(application: *Application, pane: *PaneType) !void {
            var coordinator = paneObservationCoordinator(application);
            return coordinator.schedule(pane);
        }

        /// Starts media processing when the pane has pending media work and no
        /// media operation is already in flight.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleMedia(&application, pane);
        /// ```
        pub fn scheduleMedia(application: *Application, pane: *PaneType) !void {
            var coordinator = paneMediaCoordinator(application);
            return coordinator.schedule(pane);
        }

        const pane_observation_runtime_port: GenericObservationRuntimePort(Application) = .{
            .start = startPaneObservation,
            .publish_sound = publishObservedAgentSound,
            .schedule_description = dependencies.schedule_description,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneObservationCoordinator = GenericObservationCoordinator(Application, pane_observation_runtime_port);

        fn paneObservationCoordinator(application: *Application) RuntimePaneObservationCoordinator {
            return RuntimePaneObservationCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn startPaneObservation(application: *Application, work: ObservationWork) !void {
            try application.select.concurrent(.pane_observed, observePane, .{work});
        }

        fn observePane(work: ObservationWork) ObservationCompletion {
            const path = enter_module(.observation);
            defer path.restore();

            var stats: StatsType = .{};
            const process_probe = agent_process.probe(.{
                .process_group_id = work.pane.session.foregroundProcessGroup(),
                .shell_pid = work.pane.session.processId(),
                .previous = work.process_cache,
                .manifests = work.pane.manifests,
            });
            work.pane.processHistoryObservation(.{ .size = work.current_size, .provider = process_probe.cache.provider }, &stats);
            return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
        }

        fn publishObservedAgentSound(application: *Application, notification: AgentSoundNotificationType) void {
            application.publishAgentSound(notification);
        }

        const pane_media_runtime_port: GenericMediaRuntimePort(Application) = .{
            .start = startPaneMedia,
            .enforce_quotas = enforcePaneGraphicsQuotas,
            .synchronize_clients = synchronizeMediaClients,
            .schedule_response = dependencies.schedule_response,
            .pump_clients = pumpRuntimeClients,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneMediaCoordinator = GenericMediaCoordinator(Application, pane_media_runtime_port);

        fn paneMediaCoordinator(application: *Application) RuntimePaneMediaCoordinator {
            return RuntimePaneMediaCoordinator.init(application, .{
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneMedia(application: *Application, work: MediaWork) !void {
            try application.select.concurrent(.pane_media, processPaneMedia, .{work});
        }

        fn processPaneMedia(work: MediaWork) MediaCompletion {
            const path = enter_module(.media);
            defer path.restore();

            var stats: MediaStats = .{};
            const started = now_module(work.pane.io);
            work.pane.processMedia(work.current_size, &stats);
            stats.elapsed_ns = elapsed_module(started, now_module(work.pane.io));
            return .{ .pane = work.pane.key(), .stats = stats };
        }

        fn enforcePaneGraphicsQuotas(application: *Application, pane: *PaneType) void {
            root.enforceGraphicsQuotas(application.io, pane);
        }

        fn synchronizeMediaClients(application: *Application, pane: *PaneType, reset: bool) PaneStats {
            var stores: [store_support.max_clients]*AttachmentStoreType = undefined;
            var count: usize = 0;

            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                stores[count] = &client.attachments;
                count += 1;
            }

            return media_projection_module.synchronize(pane, stores[0..count], reset);
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}
